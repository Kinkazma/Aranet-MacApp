import Foundation
import CoreBluetooth

// MARK: - Big-endian helpers
private extension Data {
    @inline(__always) func beUInt16(at offset: Int) -> UInt16 {
        precondition(count >= offset + 2, "Data too short")
        return withUnsafeBytes { ptr in
            let raw = ptr.load(fromByteOffset: offset, as: UInt16.self)
            return UInt16(bigEndian: raw)
        }
    }
    @inline(__always) func beInt16(at offset: Int) -> Int16 {
        precondition(count >= offset + 2, "Data too short")
        return withUnsafeBytes { ptr in
            let raw = ptr.load(fromByteOffset: offset, as: Int16.self)
            return Int16(bigEndian: raw)
        }
    }
}

/// Service gérant la communication Bluetooth avec l'Aranet4 via Core Bluetooth.
/// Il fournit des méthodes pour scanner et se connecter à l'appareil, lire la mesure courante,
/// récupérer l'historique et modifier la fréquence de mesure.
class Aranet4Service: NSObject, ObservableObject {
    /// Central manager utilisé pour scanner et se connecter aux périphériques BLE.
    private var centralManager: CBCentralManager!
    /// Périphérique Aranet4 détecté.
    private var peripheral: CBPeripheral?
    /// Caractéristiques utilisées pour les lectures courantes et historiques.
    private var currentReadingsCharacteristic: CBCharacteristic?
    private var historyCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var totalReadingsCharacteristic: CBCharacteristic?
    private var intervalCharacteristic: CBCharacteristic?
    /// Caractéristique indiquant le nombre de secondes écoulées depuis la dernière mesure.
    private var secondsSinceUpdateCharacteristic: CBCharacteristic?

    /// DeviceID courant (UUID du périphérique BLE) pour annoter chaque mesure.
    private(set) var currentDeviceID: UUID?

    /// Identifiant logique de l'appareil sélectionné dans l'interface.  Si défini, chaque mesure sera
    /// insérée dans l'historique associé à cet identifiant plutôt qu'à celui du périphérique BLE.
    @Published var logicalDeviceID: UUID?

    /// Stockage (injecté depuis l'App) pour insérer les mesures par appareil.
    /// Optionnel et utilisé de façon opportuniste.
    var storage: HistoryStorage?

    @Published var isConnected: Bool = false
    @Published var currentRecord: MeasurementRecord?
    @Published var records: [MeasurementRecord] = []

    // MARK: - Historique et état courant

    /// Nombre total de lectures disponibles sur l'appareil (via f0cd2001).
    private var totalReadingsCount: Int?
    /// Intervalle de mesure en secondes (via f0cd2002).  Converti en secondes si certains firmwares renvoient en minutes.
    private var measurementIntervalSeconds: Int?
    /// Âge de la dernière mesure en secondes (via f0cd2004).
    private var lastReadingAgeSeconds: Int?
    /// Indique si une récupération d'historique est en cours afin d'éviter plusieurs appels concurrents.
    private var isFetchingHistory: Bool = false
    /// Nombre restant d'enregistrements d'historique à récupérer (décroît à chaque paquet).
    private var historyRemainingRecords: Int = 0

    // MARK: - Info (firmware/battery) read state
    /// Stocke la completion à appeler lorsque la lecture d'informations standard est terminée.  L'appel
    /// fournit le firmware (String?), le niveau de batterie (Int?) et l'intervalle de mesure (Int?).
    private var pendingInfoCompletion: ((String?, Int?, Int?) -> Void)?
    /// Valeur partielle pour le firmware lue lors de la lecture des caractéristiques standard.
    private var pendingInfoFW: String?
    /// Valeur partielle pour le niveau de batterie lue lors de la lecture des caractéristiques standard.
    private var pendingInfoBatt: Int?

    // Services/Chars standards pour la lecture du firmware et de la batterie
    private let infoServiceUUID = CBUUID(string: "180A")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let firmwareCharUUID = CBUUID(string: "2A26")
    private let batteryLevelCharUUID = CBUUID(string: "2A19")

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Lance le scan des périphériques BLE pour trouver l'Aranet4.
    func startScanning() {
        // Si le central n'est pas encore prêt, il lancera le scan lors de la mise à jour d'état.
        guard centralManager.state == .poweredOn else { return }
        print("Démarrage du scan BLE…")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Demande la mesure courante à l'Aranet4.  Une fois la lecture terminée,
    /// `currentRecord` est mis à jour.
    func fetchCurrentReading() {
        guard let peripheral = peripheral, let char = currentReadingsCharacteristic else { return }
        peripheral.readValue(for: char)
    }

    /// Récupère l'historique complet et l'ajoute au stockage.  Ce squelette se base sur
    /// l'implémentation de référence en Python.  La méthode envoie une commande au
    /// périphérique puis traite les notifications reçues pour constituer les enregistrements.
    /// Les données sont ensuite ajoutées au `HistoryStorage` passé en paramètre et un fichier
    /// CSV est créé pour ce lot.  À adapter en fonction de l'évolution du firmware.
    func fetchHistoryAndUpdateStorage(storage: HistoryStorage) {
        // Ce squelette illustre la démarche sans implémenter toute la logique bas niveau.
        // 1. Lire le nombre total de mesures pour déterminer l'index de départ.
        guard let peripheral = peripheral,
              commandCharacteristic != nil,
              historyCharacteristic != nil,
              let totalChar = totalReadingsCharacteristic
        else {
            print("Bluetooth non prêt pour la récupération de l'historique.")
            return
        }
        // Lire le nombre total de lectures enregistrées.
        peripheral.readValue(for: totalChar)
        // Le callback `didUpdateValueFor` pour `totalChar` doit stocker ce nombre et déclencher la suite.
        // Dans cette esquisse, on suppose qu'une fois la valeur lue, `historyCharacteristic` enverra les blocs.
        // Ici, on lance simplement `fetchCurrentReading()` comme démonstration.
        fetchCurrentReading()
        // Dans un code complet, on utiliserait la commande 0x61 (ou 0x82) avec l'index de départ.
        // Après réception de tous les blocs, on construirait un tableau de `MeasurementRecord` et:
        // storage.add(records: newRecords)
        // try? storage.saveLog(for: newRecords)
    }

    /// Modifie l'intervalle de mesure en minutes (valeurs autorisées : 1, 2, 5, 10).
    func setMeasurementInterval(minutes: UInt8) {
        guard let peripheral = peripheral, let cmdChar = commandCharacteristic else { return }
        // Commande 0x90 suivie de l'intervalle en minutes (un octet)
        let bytes: [UInt8] = [0x90, minutes]
        let data = Data(bytes)
        peripheral.writeValue(data, for: cmdChar, type: .withResponse)
    }

    /// Lecture simplifiée des informations standards (firmware et niveau de batterie) via les services
    /// définis par le standard BLE (Device Information Service et Battery Service).  Cette méthode
    /// s'appuie sur la connexion BLE déjà ouverte et déclenche la découverte des services et
    /// caractéristiques nécessaires.  La completion est appelée sur le thread appelant avec le
    /// firmware, la batterie et l'intervalle de mesure lorsque disponibles.  Si la connexion n'est
    /// pas encore établie ou si une erreur survient, les valeurs retournées peuvent être nil.
    ///
    /// - Parameter completion: closure appelée lorsque la lecture est terminée.  Fournit le
    ///   firmware (String?), la batterie (Int?) et l'intervalle (Int?) respectivement.
    @MainActor
    func readStandardInfo(completion: @escaping (String?, Int?, Int?) -> Void) {
        // Utilise la connexion déjà ouverte
        guard let p = self.peripheral else {
            // Aucun périphérique connecté : renvoie l'intervalle déjà connu
            completion(nil, nil, self.measurementIntervalSeconds)
            return
        }
        // Initialise l'état temporaire
        self.pendingInfoCompletion = completion
        self.pendingInfoFW = nil
        self.pendingInfoBatt = nil
        // Demande la découverte uniquement des services standards nécessaires.  La lecture des
        // caractéristiques se fera dans les callbacks CBPeripheralDelegate.
        p.discoverServices([infoServiceUUID, batteryServiceUUID])
    }
}

import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

// Preferences management for Dock and Status Bar (extension)
final class AppPreferences: ObservableObject {
    @AppStorage("pref.showDock") var showDock: Bool = true { didSet { enforceInvariants(changed: .dock) } }
    @AppStorage("pref.showStatusItem") var showStatusItem: Bool = true { didSet { enforceInvariants(changed: .status) } }
    @AppStorage("pref.lastEnabledWasDock") var lastEnabledWasDock: Bool = true

    private enum Changed { case dock, status, none }

    init() {
        // Ensure a valid state at startup
        enforceInvariants(changed: .none)
    }

    /// Guarantees that at least one surface (Dock or Status Bar) remains enabled.
    private func enforceInvariants(changed: Changed) {
        if !showDock && !showStatusItem {
            if lastEnabledWasDock {
                // Re-enable Dock if both became false
                showDock = true
            } else {
                showStatusItem = true
            }
            return
        }
        // Update the last active hint when exactly one is enabled
        if showDock && !showStatusItem {
            lastEnabledWasDock = true
        } else if showStatusItem && !showDock {
            lastEnabledWasDock = false
        } else {
            // both true → keep previous memory; nothing to do
        }
    }
}

/// Manages the app activation policy (Dock icon) and the status bar icon.
@MainActor final class ActivationManager: ObservableObject {
    static let shared = ActivationManager()

    func apply(preferences: AppPreferences) {
        setActivationPolicy(showDock: preferences.showDock)
        StatusBarManager.shared.setVisible(preferences.showStatusItem)
    }

    private func setActivationPolicy(showDock: Bool) {
        #if os(macOS)
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        if showDock {
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }
}

/// Settings UI showing toggles for Dock and status bar (extension).
struct SettingsView: View {
    @EnvironmentObject var prefs: AppPreferences

    var body: some View {
        Form {
            Section("Affichage") {
                Toggle("Afficher dans le Dock", isOn: $prefs.showDock)
                Toggle("Afficher l’extension (barre de menus)", isOn: $prefs.showStatusItem)
                Text("Au moins une des deux options doit rester activée.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Point d’entrée de l’application macOS (corrige l’absence de `@main`).
@main
struct Aranet4MacApp: App {
    @StateObject private var storage = HistoryStorage()
    @StateObject private var aranetService = Aranet4Service()
    @StateObject private var scheduler = Scheduler()
    /// Preferences controlling Dock and status bar visibility
    @StateObject private var prefs = AppPreferences()

    var body: some Scene {
        WindowGroup {
            // Si votre projet contient déjà `ContentView`, on l’utilise.
            // Sinon, la vue minimale ci‑dessous permettra au moins de compiler/lancer.
            if #available(macOS 13.0, *) {
                ContentView()
                    .environmentObject(storage)
                    .environmentObject(aranetService)
                    .environmentObject(scheduler)
                    .environmentObject(prefs)
                    .onAppear {
                        aranetService.storage = storage
                        ActivationManager.shared.apply(preferences: prefs)
                    }
                    .onChange(of: prefs.showDock) { _ in
                        ActivationManager.shared.apply(preferences: prefs)
                    }
                    .onChange(of: prefs.showStatusItem) { _ in
                        ActivationManager.shared.apply(preferences: prefs)
                    }
            } else {
                MinimalContentView()
                    .environmentObject(aranetService)
                    .environmentObject(prefs)
                    .onAppear {
                        aranetService.storage = storage
                        ActivationManager.shared.apply(preferences: prefs)
                    }
                    .onChange(of: prefs.showDock) { _ in
                        ActivationManager.shared.apply(preferences: prefs)
                    }
                    .onChange(of: prefs.showStatusItem) { _ in
                        ActivationManager.shared.apply(preferences: prefs)
                    }
            }
        }
        // Preferences window
        Settings {
            SettingsView()
                .environmentObject(prefs)
        }
    }
}

/// Vue de secours très simple au cas où `ContentView` n’existerait pas encore dans le projet.
struct MinimalContentView: View {
    @EnvironmentObject var service: Aranet4Service
    @State private var lastReading: String = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aranet4 Mac – Démo minimale").font(.title2).bold()
            HStack(spacing: 12) {
                Button("Scanner / Connecter") { service.startScanning() }
                Button("Mesure courante") { service.fetchCurrentReading() }
            }
            Text("Lecture: \(lastReading)")
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .onReceive(service.$currentRecord) { rec in
            guard let rec = rec else { return }
            lastReading = String(format: "CO₂: %d ppm | T: %.2f °C | RH: %.1f %% | P: %.1f hPa", rec.co2, rec.temperature, rec.humidity, rec.pressure)
        }
        .frame(minWidth: 520, minHeight: 220)
    }
}


// MARK: - CBCentralManagerDelegate

extension Aranet4Service: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth actif, lancement du scan…")
            startScanning()
        case .poweredOff:
            print("Bluetooth désactivé")
        case .unsupported:
            print("Bluetooth LE non supporté sur cet appareil")
        case .unauthorized:
            print("Accès Bluetooth non autorisé")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Filtrer par nom d'appareil pour reconnaître l'Aranet4.
        if let name = peripheral.name, name.lowercased().contains("aranet") {
            print("Périphérique trouvé : \(name)")
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connecté à l'Aranet4")
        // Mémorise l'ID BLE comme deviceID applicatif
        self.currentDeviceID = peripheral.identifier
        isConnected = true
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Échec de connexion: \(error?.localizedDescription ?? "inconnu")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Déconnecté de l'Aranet4")
        isConnected = false
        // Relancer le scan pour se reconnecter automatiquement
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate

extension Aranet4Service: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Si nous sommes en train de lire les informations standard (firmware/batterie), traiter
        // séparément la découverte de services en se concentrant sur les services 180A/180F.
        if pendingInfoCompletion != nil {
            // En cas d'erreur, terminer immédiatement en renvoyant ce qui est connu
            guard error == nil else {
                let done = pendingInfoCompletion
                pendingInfoCompletion = nil
                done?(nil, nil, self.measurementIntervalSeconds)
                return
            }
            // Parcourir les services découverts et lancer la découverte des caractéristiques
            for s in peripheral.services ?? [] {
                switch s.uuid {
                case infoServiceUUID:
                    // Firmware revision
                    peripheral.discoverCharacteristics([firmwareCharUUID], for: s)
                case batteryServiceUUID:
                    // Battery level
                    peripheral.discoverCharacteristics([batteryLevelCharUUID], for: s)
                default:
                    break
                }
            }
            // Ne pas exécuter la logique générique ci-dessous lorsqu'on est dans ce mode
        } else {
            if let error = error {
                print("Erreur lors de la découverte des services: \(error)")
                return
            }
            guard let services = peripheral.services else { return }
            for service in services {
                // Découvrir toutes les caractéristiques pour chaque service
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Si nous avons une lecture d'info en attente, se concentrer uniquement sur les caractéristiques
        // standards et lire leur valeur.
        if pendingInfoCompletion != nil {
            guard error == nil else {
                let done = pendingInfoCompletion
                pendingInfoCompletion = nil
                done?(nil, nil, self.measurementIntervalSeconds)
                return
            }
            for c in service.characteristics ?? [] {
                if c.uuid == firmwareCharUUID || c.uuid == batteryLevelCharUUID {
                    peripheral.readValue(for: c)
                }
            }
            return
        }
        if let error = error {
            print("Erreur lors de la découverte des caractéristiques: \(error)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            let uuidString = characteristic.uuid.uuidString.lowercased()
            switch uuidString {
            case "f0cd3001-95da-4f4b-9ac8-aa55d312af0c":
                // Lecture courante détaillée
                currentReadingsCharacteristic = characteristic
                // Activer les notifications lorsque disponible. Certaines versions du firmware ne notifient pas, mais cela n'est pas gênant.
                peripheral.setNotifyValue(true, for: characteristic)
                // Lire immédiatement pour obtenir une première valeur.
                peripheral.readValue(for: characteristic)
            case "f0cd2005-95da-4f4b-9ac8-aa55d312af0c":
                // Historique V2 (paquets combinés)
                historyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case "f0cd1402-95da-4f4b-9ac8-aa55d312af0c":
                // Caractéristique de commande : permet d'envoyer les commandes 0x61/0x82
                commandCharacteristic = characteristic
            case "f0cd2001-95da-4f4b-9ac8-aa55d312af0c":
                // Nombre total de lectures en mémoire (u16 LE)
                totalReadingsCharacteristic = characteristic
                // Lire tout de suite afin de déclencher potentiellement la récupération d'historique
                peripheral.readValue(for: characteristic)
            case "f0cd2002-95da-4f4b-9ac8-aa55d312af0c":
                // Intervalle de mesure (u16 LE en secondes)
                intervalCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            case "f0cd2004-95da-4f4b-9ac8-aa55d312af0c":
                // Secondes depuis la dernière mise à jour
                secondsSinceUpdateCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Erreur de lecture sur \(characteristic.uuid): \(error)")
            return
        }
        guard let data = characteristic.value else { return }
        let uuidString = characteristic.uuid.uuidString.lowercased()
        switch uuidString {
        case "f0cd3001-95da-4f4b-9ac8-aa55d312af0c":
            // Mesure courante
            if let record = decodeCurrentReading(data: data) {
                DispatchQueue.main.async {
                    self.currentRecord = record
                    self.records.append(record)
                    // Enregistre dans le stockage si présent, en utilisant l'identifiant logique si disponible
                    if let storage = self.storage {
                        let targetID = self.logicalDeviceID ?? self.currentDeviceID
                        if let devID = targetID {
                            Task { @MainActor in
                                storage.insert(records: [record], for: devID)
                            }
                        }
                    }
                }
            }
        case "f0cd2001-95da-4f4b-9ac8-aa55d312af0c":
            // Total readings (u16 LE)
            let raw: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
            self.totalReadingsCount = Int(UInt16(littleEndian: raw))
            print("Total readings count: \(self.totalReadingsCount ?? -1)")
            maybeStartHistoryFetch()
        case "f0cd2002-95da-4f4b-9ac8-aa55d312af0c":
            // Interval en secondes (u16 LE).  Certains firmwares renvoient en minutes (valeurs < 30) ; on convertit.
            let raw: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
            var interval = Int(UInt16(littleEndian: raw))
            if interval > 0 && interval <= 30 { interval *= 60 }
            self.measurementIntervalSeconds = interval
            print("Measurement interval (s): \(interval)")
            maybeStartHistoryFetch()
        case "f0cd2004-95da-4f4b-9ac8-aa55d312af0c":
            // Seconds since update (u16 LE)
            let raw: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
            self.lastReadingAgeSeconds = Int(UInt16(littleEndian: raw))
            print("Seconds since last update: \(self.lastReadingAgeSeconds ?? -1)")
            maybeStartHistoryFetch()
        case "f0cd2005-95da-4f4b-9ac8-aa55d312af0c":
            // Paquet d'historique V2 : structure [param (u8), startIndex (u16 LE), count (u8), data...]
            handleHistoryPacketV2(data: data)
        default:
            break
        }

        // Traitement des lectures standard (firmware/batterie).  On agrège les valeurs lues et
        // on déclenche la completion lorsque les deux ont été obtenues ou lorsqu'il est temps de
        // renvoyer ce qui est disponible.  Ne pas oublier l'intervalle déjà connu.
        if pendingInfoCompletion != nil {
            // Capture les données lues si l'UUID correspond
            if error == nil {
                if let v = characteristic.value {
                    if characteristic.uuid == firmwareCharUUID {
                        pendingInfoFW = String(data: v, encoding: .utf8)
                    } else if characteristic.uuid == batteryLevelCharUUID, let b = v.first {
                        pendingInfoBatt = Int(b)
                    }
                }
            }
            // On vérifie si nous avons déjà reçu les deux valeurs (firmware et batterie).  Dès qu'elles
            // sont présentes, on appelle la completion et on réinitialise l'état.  Certains firmwares
            // peuvent ne pas exposer l'un des services, mais dans ce cas la logique précédente dans
            // didDiscoverServices assure une terminaison rapide.
            let haveFW = (pendingInfoFW != nil)
            let haveBatt = (pendingInfoBatt != nil)
            if haveFW && haveBatt {
                let done = pendingInfoCompletion
                let fw = pendingInfoFW
                let batt = pendingInfoBatt
                let interval = self.measurementIntervalSeconds
                // Réinitialise l'état avant d'appeler la completion
                pendingInfoCompletion = nil
                pendingInfoFW = nil
                pendingInfoBatt = nil
                done?(fw, batt, interval)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Erreur d'abonnement aux notifications: \(error)")
        }
    }
}

// MARK: - Décodage des données

extension Aranet4Service {
    /// Transforme les données brutes lues depuis la caractéristique « current reading » en `MeasurementRecord`.
    ///
    /// La documentation de l'Aranet4 indique que chaque mesure courante est encodée sur au moins 7 octets en little‑endian:
    ///
    /// - Octets 0‑1 : concentration de CO₂ en ppm (UInt16 little‑endian)
    /// - Octets 2‑3 : température multipliée par 20 (Int16 little‑endian) ⇒ °C = valeur / 20
    /// - Octets 4‑5 : pression multipliée par 10 (UInt16 little‑endian) ⇒ hPa = valeur / 10
    /// - Octet 6 : humidité relative en pourcentage (UInt8)
    ///
    /// Les octets optionnels suivants (7 +) fournissent l’état de la batterie, la couleur d’alerte, l’intervalle de mesure
    /// et l’âge de la mesure.  Lorsque l’intervalle et l’âge sont présents, ils sont encodés en little‑endian sur deux
    /// octets chacun (positions 9‑10 pour l’intervalle en secondes et 11‑12 pour l’âge en secondes).  Sur certains
    /// firmwares plus anciens, les positions 9 et 10 contiennent respectivement l’intervalle et l’âge en minutes.
    ///
    /// Ce décodage corrige ainsi les problèmes observés avec des valeurs incohérentes (CO₂ de plusieurs dizaines de
    /// milliers, température négative de plusieurs centaines de degrés, humidité > 100 %) en appliquant le bon ordre
    /// d’octets et les bons facteurs de conversion.
    fileprivate func decodeCurrentReading(data: Data, now: Date = Date()) -> MeasurementRecord? {
        // Il faut au moins les 7 premiers octets (CO₂, température, pression, humidité).
        guard data.count >= 7 else { return nil }

        // CO₂ en ppm (UInt16 little‑endian).  Aucun facteur d’échelle n’est nécessaire.
        let co2Raw: UInt16 = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 0, as: UInt16.self)
        }
        let co2 = Int(UInt16(littleEndian: co2Raw))

        // Température en 1/20 °C (Int16 little‑endian).
        let tempRaw: Int16 = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 2, as: Int16.self)
        }
        let tValue = Int16(littleEndian: tempRaw)
        let temperature = Double(tValue) / 20.0

        // Pression en 1/10 hPa (UInt16 little‑endian).
        let pressRaw: UInt16 = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 4, as: UInt16.self)
        }
        let pValue = UInt16(littleEndian: pressRaw)
        let pressure = Double(pValue) / 10.0

        // Humidité relative en pourcentage (UInt8).
        let humidity = Double(data[6])

        // Calcul du timestamp.  Par défaut on utilise l’instant présent si aucun âge n’est fourni.
        var timestamp = now
        if data.count >= 13 {
            // Intervalle et âge fournis en secondes sur deux octets little‑endian chacun.
            let intervalLE: UInt16 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 9, as: UInt16.self)
            }
            let ageLE: UInt16 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 11, as: UInt16.self)
            }
            let intervalSec = Int(UInt16(littleEndian: intervalLE))
            let ageSec = Int(UInt16(littleEndian: ageLE))
            // L’âge représente le nombre de secondes écoulées depuis la mesure → on soustrait directement ageSec.
            timestamp = now.addingTimeInterval(-Double(ageSec))
            // L’intervalle peut être utile pour d’autres traitements mais n’est pas utilisé ici.
            _ = intervalSec
        } else if data.count >= 11 {
            // Fallback pour anciens firmwares : âge et intervalle codés sur un octet en minutes (positions 9 et 10).
            let intervalMin = Int(data[9])
            let ageMin = Int(data[10])
            timestamp = now.addingTimeInterval(-Double(ageMin * intervalMin) * 60.0)
        }

        return MeasurementRecord(timestamp: timestamp,
                                 co2: co2,
                                 temperature: temperature,
                                 humidity: humidity,
                                 pressure: pressure)
    }

    /// Décode un bloc d'historique composé d'enregistrements consécutifs (8 octets par point : CO₂, T, P, RH).
    /// `start` est l'horodatage du premier point, `intervalSeconds` l'intervalle régulier entre points.
    /// Ajustez si votre firmware fournit un autre format.
    fileprivate func decodeHistoryChunk(_ data: Data, start: Date, intervalSeconds: Int) -> [MeasurementRecord] {
        // L’historique retourne un tableau de mesures consécutives.  La taille d’une entrée peut varier selon
        // le firmware : 7 octets (CO₂, T, P, humidité sur 1 octet) ou 8 octets (humidité sur 2 octets * 100).
        // On tente d’inférer la taille en fonction de la divisibilité du bloc.
        let stride: Int
        if data.count % 7 == 0 {
            stride = 7
        } else if data.count % 8 == 0 {
            stride = 8
        } else {
            return []
        }
        let count = data.count / stride
        var records: [MeasurementRecord] = []
        records.reserveCapacity(count)

        for i in 0..<count {
            let base = i * stride
            // CO₂ (UInt16 little‑endian)
            let co2Raw: UInt16 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: base + 0, as: UInt16.self)
            }
            let co2 = Int(UInt16(littleEndian: co2Raw))
            // Température (Int16 little‑endian) / 20
            let tRawLE: Int16 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: base + 2, as: Int16.self)
            }
            let tVal = Int16(littleEndian: tRawLE)
            let temperature = Double(tVal) / 20.0
            // Pression (UInt16 little‑endian) / 10
            let pRawLE: UInt16 = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: base + 4, as: UInt16.self)
            }
            let pVal = UInt16(littleEndian: pRawLE)
            let pressure = Double(pVal) / 10.0
            // Humidité : dépend de la taille d’entrée.  Si 7 octets → 1 byte (%), sinon 2 bytes → /100.
            let humidity: Double
            if stride == 7 {
                humidity = Double(data[base + 6])
            } else {
                let rhRawLE: UInt16 = data.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: base + 6, as: UInt16.self)
                }
                let rhVal = UInt16(littleEndian: rhRawLE)
                humidity = Double(rhVal) / 100.0
            }
            // Timestamp basé sur l’intervalle fourni à cette fonction
            let ts = start.addingTimeInterval(Double(i * intervalSeconds))
            records.append(MeasurementRecord(timestamp: ts,
                                             co2: co2,
                                             temperature: temperature,
                                             humidity: humidity,
                                             pressure: pressure))
        }
        return records
    }

    /// Si toutes les métadonnées de l'historique sont connues, lance la requête V2 pour récupérer les données enregistrées.
    private func maybeStartHistoryFetch() {
        // Vérifie que nous ne sommes pas déjà en train de récupérer l'historique et que les informations nécessaires sont disponibles
        guard !isFetchingHistory,
              let total = totalReadingsCount, total > 0,
              let _ = measurementIntervalSeconds, let _ = lastReadingAgeSeconds,
              let peripheral = peripheral,
              let cmdChar = commandCharacteristic,
              let _ = historyCharacteristic
        else { return }
        isFetchingHistory = true
        historyRemainingRecords = total
        // Envoyer commande V2 (0x61) pour demander tout l'historique param=4 (CO2) à partir de l'index 1 (little-endian)
        var payload = Data()
        payload.append(0x61)
        payload.append(0x04) // param 4: CO2, qui déclenche un flux combiné
        payload.append(contentsOf: [0x01, 0x00]) // start index = 1 (u16 LE)
        peripheral.writeValue(payload, for: cmdChar, type: .withResponse)
    }

    /// Traite un paquet d'historique V2 envoyé par la caractéristique f0cd2005.
    private func handleHistoryPacketV2(data: Data) {
        guard data.count >= 4 else { return }
        // premier octet: param (ignoré ici)
        _ = data[0]
        // start index (u16 LE)
        let startLE: UInt16 = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 1, as: UInt16.self)
        }
        let startIndex = Int(UInt16(littleEndian: startLE))
        // count (u8)
        _ = Int(data[3])
        // data bytes
        let payload = data.advanced(by: 4)
        guard let total = totalReadingsCount,
              let intervalSec = measurementIntervalSeconds,
              let ageSec = lastReadingAgeSeconds else {
            return
        }
        // Calcule l'horodatage du premier point de l'historique
        let now = Date()
        let lastDate = now.addingTimeInterval(-Double(ageSec))
        let firstDate = lastDate.addingTimeInterval(-Double((total - 1) * intervalSec))
        // L'index de base (1‑based). startIndex indique la position du premier élément dans ce paquet.
        let recordOffset = startIndex - 1
        let chunkStartDate = firstDate.addingTimeInterval(Double(recordOffset * intervalSec))
        let records = decodeHistoryChunk(payload, start: chunkStartDate, intervalSeconds: intervalSec)
        // Mettre à jour le nombre restant et stocker
        historyRemainingRecords -= records.count
        // Ajouter dans la liste interne et dans le stockage
        DispatchQueue.main.async {
            self.records.append(contentsOf: records)
            if let storage = self.storage, let devID = self.currentDeviceID {
                Task { @MainActor in
                    storage.insert(records: records, for: devID)
                }
            }
        }
        // Si tout l'historique a été récupéré, marquer comme terminé
        if historyRemainingRecords <= 0 {
            isFetchingHistory = false
            print("Récupération historique terminée")
        }
    }
}
