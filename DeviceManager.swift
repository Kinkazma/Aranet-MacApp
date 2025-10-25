//
//  DeviceManager.swift
//  Aranet4MacApp
//
//  Created by Gael Dauchy on 24/10/2025.
//

import Foundation
import CoreBluetooth

/// Gère le scan, l'association (connexion), le renommage et la récupération d'infos (firmware/batterie/intervalle) des appareils.
/// N'impacte aucun autre fichier. L'intégration avec l'historique/mesures se fera dans une étape séparée.
@MainActor
final class DeviceManager: NSObject, ObservableObject {
    // MARK: - Published state
    
    @Published private(set) var devices: [Device] = []
    @Published var selectedDeviceID: UUID?
    @Published private(set) var isScanning: Bool = false
    
    // MARK: - BLE
    private var central: CBCentralManager!
    private var peripheralsByBLEID: [UUID: CBPeripheral] = [:]
    private var deviceIDByPeripheral: [UUID: UUID] = [:] // peripheral.identifier -> Device.id
    
    // MARK: - Persistence
    private let devicesURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let app = dir.appendingPathComponent("Aranet4MacApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app.appendingPathComponent("devices.json")
    }()
    
    // MARK: - Known UUIDs (optional filters)
    private let deviceInfoService = CBUUID(string: "180A") // Firmware Revision String (2A26)
    private let batteryService = CBUUID(string: "180F")   // Battery Level (2A19)
    private let firmwareRevisionChar = CBUUID(string: "2A26")
    private let batteryLevelChar = CBUUID(string: "2A19")
    // Aranet4 a des services/characteristics propriétaires pour les mesures.
    // Ici, on ne les utilise pas encore (étape séparée).
    private let aranetServiceHint = CBUUID(string: "F0CD3000-95DA-4F4B-9AC8-AA55D312AF0C") // best-effort (utilisé comme hint)
    
    // MARK: - Init
    
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        loadDevices()
    }
    
    // MARK: - Public API
    
    func startScanning() {
        guard central.state == .poweredOn else {
            isScanning = true // marquer l'intention: on scannera dès que poweredOn
            return
        }
        let services: [CBUUID]? = [deviceInfoService, batteryService, aranetServiceHint]
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }
    
    func stopScanning() {
        central.stopScan()
        isScanning = false
    }
    
    /// Connecte l'appareil (par BLE). Ajoute si inconnu.
    func connect(_ device: Device) {
        guard let p = peripheralsByBLEID[device.bleID] else {
            // On ne l'a pas encore en main : tenter de rescanner rapidement
            startScanning()
            return
        }
        deviceIDByPeripheral[p.identifier] = device.id
        central.connect(p, options: nil)
    }
    
    /// Déconnecte si connecté.
    func disconnect(_ device: Device) {
        guard let p = peripheralsByBLEID[device.bleID] else { return }
        central.cancelPeripheralConnection(p)
    }
    
    /// Renomme l'alias local (persistance incluse).
    func rename(deviceID: UUID, to newName: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[idx].name = newName
        saveDevices()
    }
    
    /// Sélectionne l'appareil courant pour l'UI.
    func select(deviceID: UUID?) {
        selectedDeviceID = deviceID
    }
    
    /// Force la récupération d'infos standard (firmware/batterie) si possible.
    func refreshInfo(for deviceID: UUID) {
        guard let dev = devices.first(where: { $0.id == deviceID }),
              let p = peripheralsByBLEID[dev.bleID] else { return }
        deviceIDByPeripheral[p.identifier] = dev.id
        if p.state == .connected {
            p.discoverServices([deviceInfoService, batteryService])
        } else {
            central.connect(p, options: nil)
        }
    }
    
    // MARK: - Helpers

    /// Duplique un appareil logique (même bleID, nouvel id, nom modifié)
    func duplicate(deviceID: UUID) {
        guard let existing = devices.first(where: { $0.id == deviceID }) else { return }
        // Génère un suffixe aléatoire court pour différencier cette copie.
        let suffix = randomAliasSuffix()
        let newName = suffix.isEmpty ? existing.name : "\(existing.name)-\(suffix)"
        let newDevice = Device(
            id: UUID(),
            bleID: existing.bleID,
            name: newName,
            info: existing.info
        )
        devices.append(newDevice)
        // Sélectionner la nouvelle copie pour que l’utilisateur voie immédiatement
        // l’appareil créé.  Cette sélection déclenchera l’utilisation de son
        // historique dédié dans l’interface.
        selectedDeviceID = newDevice.id
        saveDevices()
    }
    
    private func upsertDevice(from peripheral: CBPeripheral) {
        let bleID = peripheral.identifier
        if let _ = devices.firstIndex(where: { $0.bleID == bleID }) {
            // Ne mettez pas à jour le nom automatiquement pour préserver les alias
            // personnalisés.  Les utilisateurs peuvent renommer les appareils
            // manuellement via l'interface.
        } else {
            // Crée un nom par défaut pour l'appareil.  Utilise le nom BLE s'il est
            // disponible et non vide, sinon génère un alias hexadécimal.  Le nom
            // aléatoire permet d'identifier plusieurs instances logiques d'un même
            // appareil sans ambiguïté.  Exemple : « Aranet4 » ou « Aranet4-A1B2 ».
            let baseName = (peripheral.name?.isEmpty == false ? peripheral.name! : "Aranet4")
            let aliasSuffix = randomAliasSuffix()
            let displayName = aliasSuffix.isEmpty ? baseName : "\(baseName)-\(aliasSuffix)"
            let dev = Device(bleID: bleID, name: displayName, info: nil)
            devices.append(dev)
            // Sélectionner automatiquement le premier appareil ajouté si aucun n'est encore sélectionné.
            if selectedDeviceID == nil { selectedDeviceID = dev.id }
        }
        saveDevices()
    }
    
    private func updateDeviceInfo(_ deviceID: UUID, mutate: (inout DeviceInfo) -> Void) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        var info = devices[idx].info ?? DeviceInfo()
        mutate(&info)
        devices[idx].info = info
        saveDevices()
    }

    /// Met à jour les informations d'un appareil (firmware, batterie, intervalle) de manière centralisée.
    /// Cette méthode permet de fournir plusieurs valeurs à la fois sans écraser celles qui ne sont pas
    /// spécifiées.  Elle est utilisée notamment lors de la lecture via Aranet4Service pour répercuter
    /// les informations standards lues (firmware, batterie) et l'intervalle mesuré.
    func setInfo(for deviceID: UUID, firmware: String?, battery: Int?, interval: Int?) {
        updateDeviceInfo(deviceID) { info in
            if let f = firmware { info.firmware = f }
            if let b = battery { info.batteryPct = b }
            if let i = interval { info.measurementIntervalSec = i }
        }
    }
    
    private func saveDevices() {
        do {
            let data = try JSONEncoder().encode(devices)
            try data.write(to: devicesURL, options: .atomic)
        } catch {
            print("DeviceManager saveDevices error: \(error)")
        }
    }
    
    private func loadDevices() {
        do {
            let data = try Data(contentsOf: devicesURL)
            let list = try JSONDecoder().decode([Device].self, from: data)
            self.devices = list
        } catch {
            // Pas grave au premier lancement
        }
    }
    
    /// Supprime un appareil logique et nettoie l'historique associé
    func remove(deviceID: UUID, storage: HistoryStorage?) {
        // Supprimer l'appareil de la liste
        devices.removeAll { $0.id == deviceID }
        saveDevices()

        // Nettoyer l'historique lié si fourni
        storage?.removeAll(for: deviceID)

        // Ajuster la sélection
        if selectedDeviceID == deviceID {
            selectedDeviceID = devices.first?.id
        }
    }

    // MARK: - Création et utilitaires

    /// Crée un nouvel appareil logique associé à un identifiant BLE connu.  Si
    /// l'identifiant est déjà présent dans la liste des appareils, la fonction
    /// renvoie sans rien faire.  Sinon, elle génère un nom aléatoire et
    /// sélectionne le nouvel appareil.  Cette méthode peut être utilisée lorsque
    /// un appareil est déjà connecté via `Aranet4Service` mais qu'aucune entrée
    /// logique n'existe encore dans `DeviceManager`.  L'alias généré est basé
    /// sur un suffixe hexadécimal court afin de distinguer plusieurs appareils
    /// logiques pointant vers le même périphérique physique.
    func addLogicalDevice(bleID: UUID, name: String? = nil) {
        // Ne créer qu'une seule entrée par périphérique physique
        if devices.contains(where: { $0.bleID == bleID }) {
            return
        }
        let baseName = name ?? "Aranet4"
        let suffix = randomAliasSuffix()
        let displayName = suffix.isEmpty ? baseName : "\(baseName)-\(suffix)"
        let newDevice = Device(
            id: UUID(),
            bleID: bleID,
            name: displayName,
            info: nil
        )
        devices.append(newDevice)
        // Sélectionner directement ce nouvel appareil
        selectedDeviceID = newDevice.id
        saveDevices()
    }

    /// Génère un suffixe hexadécimal court pour différencier des appareils
    /// logiques.  Utilise les quatre premiers caractères de la représentation
    /// aléatoire d'un UUID pour limiter la longueur.  Retourne une chaîne
    /// vide si aucun suffixe n'est souhaité.  Marqué `fileprivate` pour
    /// restreindre l'utilisation à ce fichier.
    fileprivate func randomAliasSuffix() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = uuid.startIndex
        let end = uuid.index(start, offsetBy: 4)
        return String(uuid[start..<end]).uppercased()
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.isScanning {
                    self.startScanning()
                }
            default:
                break
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            // Filtrage léger : on favorise "Aranet" dans le nom ou service hint présent
            let name = peripheral.name?.lowercased() ?? ""
            let looksLikeAranet = name.contains("aranet")
            let hasAranetHint = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(aranetServiceHint)) ?? false
            if !looksLikeAranet && !hasAranetHint {
                // On laisse passer quand même: certains firmwares changent le nom; à ajuster si bruit.
            }
            
            self.peripheralsByBLEID[peripheral.identifier] = peripheral
            peripheral.delegate = self
            self.upsertDevice(from: peripheral)
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Découvrir services standard pour lire firmware/batterie
            peripheral.delegate = self
            peripheral.discoverServices([deviceInfoService, batteryService])
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            print("DeviceManager: fail to connect \(peripheral.identifier) error=\(String(describing: error))")
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            // Rien de spécial; l'UI peut refléter l'état via info optionnelle si besoin
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard let services = peripheral.services else { return }
            for s in services {
                if s.uuid == deviceInfoService {
                    peripheral.discoverCharacteristics([firmwareRevisionChar], for: s)
                } else if s.uuid == batteryService {
                    peripheral.discoverCharacteristics([batteryLevelChar], for: s)
                }
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard let chars = service.characteristics else { return }
            for c in chars {
                if c.uuid == firmwareRevisionChar || c.uuid == batteryLevelChar {
                    peripheral.readValue(for: c)
                }
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            guard let deviceID = self.deviceIDByPeripheral[peripheral.identifier] ??
                    self.devices.first(where: { $0.bleID == peripheral.identifier })?.id
            else { return }
            
            if characteristic.uuid == firmwareRevisionChar, let data = characteristic.value,
               let fw = String(data: data, encoding: .utf8) {
                self.updateDeviceInfo(deviceID) { $0.firmware = fw }
            } else if characteristic.uuid == batteryLevelChar, let data = characteristic.value, let b = data.first {
                self.updateDeviceInfo(deviceID) { $0.batteryPct = Int(b) }
            }
            // Intervalle de mesure : non standard — laisser vide ici. On lira via le service Aranet4 dans une prochaine étape.
        }
    }
}
