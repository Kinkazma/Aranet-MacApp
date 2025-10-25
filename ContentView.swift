import SwiftUI
#if os(macOS)
import AppKit
#endif
import Charts
import UniformTypeIdentifiers

/// Enumération représentant les périodes prédéfinies disponibles dans l'interface.
/// Utilisé pour filtrer les mesures affichées dans les graphiques.
enum TimeRangeSelection: String, CaseIterable, Identifiable {
    case today = "Aujourd'hui"
    case week = "7 jours"
    case month = "1 mois"
    case all = "Tout"
    case custom = "Plage..."

    var id: String { rawValue }
}

/// Vue principale de l'application permettant de sélectionner une période,
/// d'afficher les graphiques des mesures et de lancer des exports CSV.
struct ContentView: View {
    @EnvironmentObject private var aranetService: Aranet4Service
    @EnvironmentObject private var storage: HistoryStorage
    @EnvironmentObject private var scheduler: Scheduler
    // Gestion multi‑appareils (local pour cette vue)
    @StateObject private var deviceManager = DeviceManager()

    // Sélection de période et dates personnalisées pour l'affichage.
    @State private var selectedRange: TimeRangeSelection = .today
    @State private var customStartDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var customEndDate: Date = Date()
    // Export: chemin du fichier CSV généré lors d'un export personnalisé.
    @State private var exportURL: URL?
    // Intervalle de récupération paramétré par l'utilisateur (en minutes).
    @State private var fetchInterval: Double = 5.0
    // Heure spécifique de récupération (optionnelle).  Par défaut, aucune heure spécifique.
    @State private var specificFetchTime: Date = Date()
    @State private var useSpecificFetchTime: Bool = false

    // MARK: - UI state pour la gestion des appareils et de l'historique
    /// Présente la feuille de renommage d'un appareil.
    @State private var showRenameSheet: Bool = false
    /// Saisie du nouveau nom lors du renommage.
    @State private var newDeviceName: String = ""
    /// Présente la feuille d'informations détaillées sur l'appareil.
    @State private var showInfoSheet: Bool = false
    /// Présente l'explorateur de fichiers CSV.
    @State private var showCSVExplorer: Bool = false
    /// Gestion de la double confirmation pour la suppression complète de l'historique.
    @State private var deleteAllConfirmationStage: Int = 0
    /// Présente la feuille de suppression par plage.
    @State private var showDeleteRangeSheet: Bool = false
    /// Début de la plage à supprimer.
    @State private var deleteRangeStart: Date = Date()
    /// Fin de la plage à supprimer.
    @State private var deleteRangeEnd: Date = Date()

    // MARK: - Computed helpers

    /// Retourne les enregistrements de base en fonction de l'appareil sélectionné.  Si aucun appareil n'est
    /// sélectionné, renvoie l'ensemble des enregistrements disponibles.
    private var baseRecords: [MeasurementRecord] {
        if let devID = deviceManager.selectedDeviceID, let recs = storage.recordsByDevice[devID] {
            return recs
        }
        return storage.records
    }

    /// Renvoie l'enregistrement le plus récent selon l'appareil sélectionné ou globalement.
    private var latestLocal: MeasurementRecord? {
        if let devID = deviceManager.selectedDeviceID, let recs = storage.recordsByDevice[devID],
           let latest = recs.max(by: { $0.timestamp < $1.timestamp }) {
            return latest
        }
        if let latest = storage.records.max(by: { $0.timestamp < $1.timestamp }) {
            return latest
        }
        return aranetService.currentRecord
    }

    /// Renvoie la liste des enregistrements filtrés selon la période sélectionnée.
    private var filteredRecordsLocal: [MeasurementRecord] {
        let now = Date()
        switch selectedRange {
        case .today:
            let start = Calendar.current.startOfDay(for: now)
            return baseRecords.filter { $0.timestamp >= start }
        case .week:
            if let start = Calendar.current.date(byAdding: .day, value: -7, to: now) {
                return baseRecords.filter { $0.timestamp >= start }
            }
            return baseRecords
        case .month:
            if let start = Calendar.current.date(byAdding: .month, value: -1, to: now) {
                return baseRecords.filter { $0.timestamp >= start }
            }
            return baseRecords
        case .all:
            return baseRecords
        case .custom:
            return baseRecords.filter { $0.timestamp >= customStartDate && $0.timestamp <= customEndDate }
        }
    }

    // MARK: - Subviews

    /// Sélecteur de période à afficher.
    @ViewBuilder
    private var periodPickerView: some View {
        Picker("Période", selection: $selectedRange) {
            ForEach(TimeRangeSelection.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(.horizontal)
    }

    /// Barre de gestion des appareils (sélection, duplication, renommage, infos, suppression).
    @ViewBuilder
    private func deviceManagementBar(_ manager: DeviceManager) -> some View {
        HStack(spacing: 12) {
            Text("Appareil")
            Picker("Appareil", selection: Binding(
                get: { manager.selectedDeviceID },
                set: { manager.select(deviceID: $0) }
            )) {
                ForEach(manager.devices, id: \.id) { dev in
                    Text(dev.name).tag(Optional(dev.id))
                }
            }
            .pickerStyle(MenuPickerStyle())
            Button("Ajouter") {
                // Lorsque l’utilisateur souhaite ajouter un appareil, on essaie en
                // priorité de dupliquer l’appareil sélectionné afin de créer
                // plusieurs instances logiques du même périphérique.  S’il n’y a
                // aucune sélection, on duplique le premier appareil de la liste.
                // Enfin, s’il n’existe aucun appareil logique mais qu’un
                // périphérique physique est connecté via `aranetService`, on
                // crée une nouvelle entrée logique directement à partir de son
                // identifiant BLE.
                if let id = manager.selectedDeviceID ?? manager.devices.first?.id {
                    manager.duplicate(deviceID: id)
                } else if let bleID = aranetService.currentDeviceID {
                    manager.addLogicalDevice(bleID: bleID)
                }
            }
            .buttonStyle(.borderless)
            if let selectedID = manager.selectedDeviceID {
                Button("Renommer") {
                    if let dev = manager.devices.first(where: { $0.id == selectedID }) {
                        newDeviceName = dev.name
                    }
                    showRenameSheet = true
                }
                .buttonStyle(.borderless)
                Button("Infos") {
                    manager.refreshInfo(for: selectedID)
                    showInfoSheet = true
                }
                .buttonStyle(.borderless)
                Button("Supprimer", role: .destructive) {
                    manager.remove(deviceID: selectedID, storage: storage)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    /// Section des graphiques affichant les mesures filtrées.
    @ViewBuilder
    private var chartsSection: some View {
        ScrollView {
            // Domaines dynamiques pour les graphiques calculés localement
            let co2Values = filteredRecordsLocal.map { Double($0.co2) }
            let minCO2 = max(co2Values.min() ?? 400, 400)
            let maxCO2 = min(co2Values.max() ?? 10000, 10000)
            let co2Domain = log10(minCO2)...log10(maxCO2)

            let temps = filteredRecordsLocal.map { $0.temperature }
            let minT = temps.min() ?? 0
            let maxT = temps.max() ?? 40
            let tempDomain = (minT - 2)...(maxT + 2)

            let pressures = filteredRecordsLocal.map { $0.pressure }
            let minP = pressures.min() ?? 800
            let maxP = pressures.max() ?? 1200
            let dynamicDomain = (minP - 5)...(maxP + 5)

            MeasurementChart(
                title: "CO₂ (ppm)",
                color: .green,
                yDomain: co2Domain,
                unit: "ppm",
                data: filteredRecordsLocal,
                valueProvider: { Double($0.co2) },
                colorProvider: { rec in
                    if rec.co2 < 900 { return Color.green }
                    if rec.co2 < 1500 { return Color.yellow }
                    return Color.red
                }
            )
            MeasurementChart(
                title: "Température (°C)",
                color: .orange,
                yDomain: tempDomain,
                unit: "°C",
                data: filteredRecordsLocal,
                valueProvider: { $0.temperature },
                colorProvider: { rec in
                    let c = rec.temperature
                    if c > 30 { return Color.red }
                    if c < 10 { return Color.cyan }
                    return Color.orange
                }
            )
            MeasurementChart(
                title: "Humidité (%)",
                color: .blue,
                yDomain: 0...100,
                unit: "%",
                data: filteredRecordsLocal,
                valueProvider: { $0.humidity }
            )
            MeasurementChart(
                title: "Pression (hPa)",
                color: .purple,
                yDomain: dynamicDomain,
                unit: "hPa",
                data: filteredRecordsLocal,
                valueProvider: { $0.pressure }
            )
        }
    }

    /// Section des contrôles de récupération automatique et d'export CSV.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Récupération automatique")
                .font(.headline)
            HStack {
                Stepper(value: $fetchInterval, in: 1...60, step: 1) {
                    Text("Intervalle: \(Int(fetchInterval)) minutes")
                }
                Toggle("Heure spécifique", isOn: $useSpecificFetchTime)
                    .toggleStyle(SwitchToggleStyle())
                if useSpecificFetchTime {
                    DatePicker("Heure", selection: $specificFetchTime, displayedComponents: .hourAndMinute)
                }
                Button("Démarrer") {
                    startScheduledFetch()
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Button("Exporter la période") {
                    exportSelectedRange()
                }
                .buttonStyle(.borderedProminent)
                Button("Exporter tout l'historique") {
                    exportFullHistory()
                }
                .buttonStyle(.bordered)
                Button("Importer un CSV…") {
                    importCSV()
                }
                .buttonStyle(.bordered)
                Button("Explorer les CSV…") {
                    showCSVExplorer = true
                }
                .buttonStyle(.bordered)
            }
            if let url = exportURL {
                Text("Exporté vers : \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Button("Supprimer tout l'historique", role: .destructive) {
                    deleteAllConfirmationStage = 1
                }
                Button("Supprimer une plage", role: .destructive) {
                    deleteRangeStart = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    deleteRangeEnd = Date()
                    showDeleteRangeSheet = true
                }
            }
        }
        .padding()
    }

    /// Section des DatePickers lorsque la plage personnalisée est sélectionnée.
    @ViewBuilder
    private var customDatePickersView: some View {
        if selectedRange == .custom {
            HStack {
                DatePicker("Début", selection: $customStartDate, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Fin", selection: $customEndDate, displayedComponents: [.date, .hourAndMinute])
            }
            .padding(.horizontal)
        }
    }

    var body: some View {
        // Calculs locaux pour déterminer la base de données, l'enregistrement le plus récent et les enregistrements filtrés.

        VStack(alignment: .leading) {
            // Sous-vues simplifiées pour réduire la complexité de type
            periodPickerView
            deviceManagementBar(deviceManager)
            if let latest = latestLocal {
                LatestReadingsView(latest: latest)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            customDatePickersView
            chartsSection
            Divider()
            controlsSection
        }
        .onAppear {
            // Démarrer le scan Bluetooth dès l'apparition de la vue
            aranetService.startScanning()
            deviceManager.startScanning()
            // S'assurer qu'un appareil est sélectionné par défaut s'il existe
            if deviceManager.selectedDeviceID == nil, let first = deviceManager.devices.first {
                deviceManager.select(deviceID: first.id)
            }
            // Synchroniser l'appareil logique sélectionné avec le service BLE
            aranetService.logicalDeviceID = deviceManager.selectedDeviceID
        }
        .frame(minWidth: 200, idealWidth: 400, maxWidth: .infinity,
               minHeight: 100, idealHeight: 1400, maxHeight: .infinity)
        #if os(macOS)
        .background(WindowAccessor { window in
            // Window sizing policy (no persistence):
            // - min content size: 200x100
            // - initial content size: 400x1400
            // - max content height: unlimited (width unlimited)
            window.contentMinSize = NSSize(width: 200, height: 100)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(NSSize(width: 400, height: 1400))
        })
        #endif
        // À chaque nouvelle mesure courante, l'ajouter au stockage et enregistrer un fichier CSV dédié.
        .onReceive(aranetService.$currentRecord.compactMap { $0 }) { record in
            // Lors de la réception d'une nouvelle mesure, l'insertion dans le stockage est désormais effectuée dans
            // Aranet4Service via logicalDeviceID.  Nous nous contentons ici de sauvegarder le log CSV.
            do {
                _ = try storage.saveLog(for: [record])
            } catch {
                print("Impossible de sauvegarder le log: \(error)")
            }
            // Si aucun appareil logique n'existe encore pour ce périphérique BLE, en créer un
            if let bleID = aranetService.currentDeviceID {
                let exists = deviceManager.devices.contains(where: { $0.bleID == bleID })
                if !exists {
                    Task { @MainActor in
                        deviceManager.addLogicalDevice(bleID: bleID)
                    }
                }
            }
        }
        // Lorsque la sélection d'appareil change, mettre à jour le service pour que les mesures
        // soient attribuées au bon identifiant logique
        .onChange(of: deviceManager.selectedDeviceID) { newID in
            aranetService.logicalDeviceID = newID
        }
        // Feuille de renommage d'appareil
        .sheet(isPresented: $showRenameSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Renommer l'appareil")
                    .font(.headline)
                TextField("Nouveau nom", text: $newDeviceName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Annuler") { showRenameSheet = false }
                    Spacer()
                    Button("Valider") {
                        if let id = deviceManager.selectedDeviceID {
                            deviceManager.rename(deviceID: id, to: newDeviceName)
                        }
                        showRenameSheet = false
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 220)
        }
        // Feuille d'informations détaillées sur l'appareil
        .sheet(isPresented: $showInfoSheet) {
            if let selectedID = deviceManager.selectedDeviceID,
               let dev = deviceManager.devices.first(where: { $0.id == selectedID }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(dev.name)
                        .font(.title2).bold()
                    Text("BLE ID : \(dev.bleID.uuidString)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Divider()
                    Group {
                        let firmware = dev.info?.firmware ?? "—"
                        let battery = dev.info?.batteryPct.map { "\($0) %" } ?? "—"
                        let interval = dev.info?.measurementIntervalSec.map { "\($0) s" } ?? "—"
                        Text("Firmware : \(firmware)")
                        Text("Batterie : \(battery)")
                        Text("Intervalle : \(interval)")
                    }
                    Divider()
                    HStack {
                        Button("Rafraîchir") {
                            // Utiliser Aranet4Service pour lire les informations standard depuis
                            // l'appareil connecté et mettre à jour le DeviceManager lorsque les
                            // valeurs sont disponibles.  Cela évite d'avoir deux centrals BLE en
                            // compétition et fournit également l'intervalle de mesure.
                            if let selectedID = deviceManager.selectedDeviceID {
                                aranetService.readStandardInfo { fw, batt, interval in
                                    Task { @MainActor in
                                        deviceManager.setInfo(for: selectedID, firmware: fw, battery: batt, interval: interval)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button("Fermer") { showInfoSheet = false }
                    }
                }
                .padding(20)
                .frame(minWidth: 320)
            } else {
                VStack {
                    Text("Aucun appareil sélectionné")
                    Button("Fermer") { showInfoSheet = false }
                }
                .padding(20)
            }
        }
        // Explorateur de fichiers CSV
        .sheet(isPresented: $showCSVExplorer) {
            CSVExplorerView(storage: storage)
        }
        // Feuille de suppression d'une plage de dates
        .sheet(isPresented: $showDeleteRangeSheet) {
            DeleteRangeSheet(storage: storage,
                             deviceID: deviceManager.selectedDeviceID,
                             initialStart: $deleteRangeStart,
                             initialEnd: $deleteRangeEnd,
                             isPresented: $showDeleteRangeSheet)
        }
        // Alertes de double confirmation pour la suppression complète
        .alert("Suppression de l'historique", isPresented: Binding(
            get: { deleteAllConfirmationStage > 0 },
            set: { val in if !val { deleteAllConfirmationStage = 0 } }
        )) {
            if deleteAllConfirmationStage == 1 {
                Button("Continuer", role: .destructive) {
                    deleteAllConfirmationStage = 2
                }
                Button("Annuler", role: .cancel) {
                    deleteAllConfirmationStage = 0
                }
            } else if deleteAllConfirmationStage == 2 {
                Button("Supprimer", role: .destructive) {
                    Task { @MainActor in
                        storage.deleteAllRecords()
                    }
                    deleteAllConfirmationStage = 0
                }
                Button("Annuler", role: .cancel) {
                    deleteAllConfirmationStage = 0
                }
            }
        } message: {
            if deleteAllConfirmationStage == 1 {
                Text("Cette action effacera définitivement toutes les mesures. Souhaitez‑vous continuer ?")
            } else {
                Text("Êtes‑vous certain de vouloir supprimer l'intégralité de l'historique ?")
            }
        }
    }

    /// Recalcule la sélection filtrée (utile pour les exports).
    private func currentFilteredRecords() -> [MeasurementRecord] {
        let base: [MeasurementRecord]
        if let devID = deviceManager.selectedDeviceID {
            base = storage.recordsByDevice[devID] ?? []
        } else {
            base = storage.records
        }
        let now = Date()
        switch selectedRange {
        case .today:
            let start = Calendar.current.startOfDay(for: now)
            return base.filter { $0.timestamp >= start }
        case .week:
            guard let start = Calendar.current.date(byAdding: .day, value: -7, to: now) else { return base }
            return base.filter { $0.timestamp >= start }
        case .month:
            guard let start = Calendar.current.date(byAdding: .month, value: -1, to: now) else { return base }
            return base.filter { $0.timestamp >= start }
        case .all:
            return base
        case .custom:
            return base.filter { $0.timestamp >= customStartDate && $0.timestamp <= customEndDate }
        }
    }

    /// Lance la planification de récupération périodique en fonction des paramètres sélectionnés.
    private func startScheduledFetch() {
        scheduler.cancel()
        if useSpecificFetchTime {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: specificFetchTime)
            let hour = comps.hour ?? 0
            let minute = comps.minute ?? 0
            scheduler.schedule(dailyAt: hour, minute: minute) {
                aranetService.fetchHistoryAndUpdateStorage(storage: storage)
            }
        } else {
            scheduler.schedule(everyMinutes: Int(fetchInterval)) {
                aranetService.fetchHistoryAndUpdateStorage(storage: storage)
            }
        }
    }

    /// Exporte la plage sélectionnée vers un fichier CSV et met à jour `exportURL`.
    private func exportSelectedRange() {
        let selection = currentFilteredRecords()
        do {
            let url = try CSVManager.export(records: selection, fileName: "history_selection.csv")
            exportURL = url
        } catch {
            print("Erreur d'export CSV: \(error)")
        }
    }

    /// Exporte toutes les mesures stockées vers un fichier CSV.
    private func exportFullHistory() {
        do {
            let url = try CSVManager.export(records: storage.records, fileName: "history_full.csv")
            exportURL = url
        } catch {
            print("Erreur d'export CSV: \(error)")
        }
    }

    /// Présente un dialogue d'importation de CSV (non implémenté dans ce squelette).
    private func importCSV() {
        // Importation de mesures depuis un fichier CSV sur macOS.
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        // Afficher le dialogue de sélection synchrone (runModal) dans ce contexte d’action de bouton.
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        // Lecture du contenu du fichier
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("Impossible de lire le fichier CSV sélectionné.")
            return
        }
        // Analyse du CSV avec rapport d’erreurs (le préfixe est le nom du fichier pour le logging).
        let (records, errors, warnings) = CSVManager.parseCSVWithReport(text, logPrefix: url.lastPathComponent)
        // Insertion dans le stockage (pour l’appareil sélectionné si applicable).
        Task { @MainActor in
            let targetDeviceID = deviceManager.selectedDeviceID
            storage.insert(records: records, for: targetDeviceID)
            do {
                // Enregistrer un log dédié pour ces nouvelles mesures
                _ = try storage.saveLog(for: records)
            } catch {
                print("Erreur lors de la sauvegarde du log d’import: \(error)")
            }
            // Mettre à jour l’URL d’export pour indiquer le fichier importé (facultatif)
            exportURL = nil
            print("Importation terminée: \(records.count) mesures importées, \(errors) erreurs, \(warnings) avertissements.")
        }
        #else
        // Sur d’autres plateformes (iOS), l’importation de fichiers n’est pas disponible dans cette implémentation.
        print("Importation CSV non disponible sur cette plateforme.")
        #endif
    }
}

/// Vue réutilisable pour représenter un graphique d'un type de mesure avec axes bornés et overlay interactif.
struct MeasurementChart: View {
    let title: String
    let color: Color
    let yDomain: ClosedRange<Double>
    let unit: String
    let data: [MeasurementRecord]
    /// Fonction qui extrait la valeur numérique à tracer depuis un enregistrement.
    let valueProvider: (MeasurementRecord) -> Double

    /// Facultatif : fournit une couleur par point en fonction de la mesure pour colorer les marqueurs individuels.
    /// Par défaut, `nil` signifie que la couleur principale s'applique.
    let colorProvider: ((MeasurementRecord) -> Color)?

    /// Initialiseur dédié afin de clarifier l'ordre des paramètres, notamment pour les closures `colorProvider` et `valueProvider`.
    init(title: String,
         color: Color,
         yDomain: ClosedRange<Double>,
         unit: String,
         data: [MeasurementRecord],
         valueProvider: @escaping (MeasurementRecord) -> Double,
         colorProvider: ((MeasurementRecord) -> Color)? = nil) {
        self.title = title
        self.color = color
        self.yDomain = yDomain
        self.unit = unit
        self.data = data
        self.valueProvider = valueProvider
        self.colorProvider = colorProvider
    }

    @State private var hoverDate: Date?

    var body: some View {
        // Transformation visuelle locale pour CO₂
        let transformedValue: (MeasurementRecord) -> Double = { record in
            let v = valueProvider(record)
            if unit == "ppm" {
                return log10(max(v, 400))
            } else {
                return v
            }
        }
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)

            Chart {
                // Courbe principale tracée sous forme de ligne continue.
                ForEach(data, id: \.timestamp) { item in
                    LineMark(
                        x: .value("Date", item.timestamp),
                        y: .value(title, transformedValue(item))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
                }

                // Si un fournisseur de couleur est défini, afficher des points colorés sur chaque enregistrement.
                if let cp = colorProvider {
                    ForEach(data, id: \.timestamp) { item in
                        PointMark(
                            x: .value("Date", item.timestamp),
                            y: .value(title, transformedValue(item))
                        )
                        .symbolSize(30)
                        .foregroundStyle(cp(item))
                    }
                }

                // Annotation pour la valeur sélectionnée lors du survol/drag.
                if let s = selectedItem {
                    RuleMark(x: .value("Date", s.timestamp))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(
                        x: .value("Date", s.timestamp),
                        y: .value(title, transformedValue(s))
                    )
                    .symbolSize(60)
                    .foregroundStyle(.primary)
                    .annotation(position: .topLeading) {
                        Text(formattedValue(for: s))
                            .font(.caption.monospacedDigit())
                            .padding(6)
                            .background(.thinMaterial)
                            .cornerRadius(6)
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    if unit == "ppm", let v = value.as(Double.self) {
                        let actual = pow(10, v)
                        let ticks: [Double] = [400, 500, 700, 1000, 1500, 2000, 5000, 10000]
                        if ticks.contains(where: { abs($0 - actual) < 30 }) {
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                Text("\(Int(actual))")
                            }
                        }
                    } else {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
            }
            .chartXAxisLabel(position: .bottom) { Text("Heure") }
            .chartYAxisLabel(position: .leading) { Text(title) }
            .frame(height: 200)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
#if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateSelection(proxy: proxy, geo: geo, location: location)
                            case .ended:
                                hoverDate = nil
                            }
                        }
#endif
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(proxy: proxy, geo: geo, location: value.location)
                            }
                            .onEnded { _ in
                                hoverDate = nil
                            }
                        )
                }
            }
        }
        .padding(.horizontal)
    }

    private var selectedItem: MeasurementRecord? {
        guard let d = hoverDate, !data.isEmpty else { return nil }
        // Trouver le point le plus proche de la date survolée
        return data.min(by: { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(d)) < abs(rhs.timestamp.timeIntervalSince(d))
        })
    }

    private func updateSelection(proxy: ChartProxy, geo: GeometryProxy, location: CGPoint) {
        // Convertir la position du curseur en valeur d'axe X (Date)
        let origin = geo[proxy.plotAreaFrame].origin
        let xInPlot = location.x - origin.x
        if let date: Date = proxy.value(atX: xInPlot) {
            hoverDate = date
        }
    }

    private func formattedValue(for item: MeasurementRecord) -> String {
        let number: Double = valueProvider(item)
        let formatted: String
        if unit == "ppm" {
            formatted = String(format: "%.0f", number)
        } else if unit == "%" {
            formatted = String(format: "%.1f", number)
        } else {
            // °C, hPa, etc.
            formatted = String(format: "%.2f", number)
        }
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return "\(formatted) \(unit) • \(df.string(from: item.timestamp))"
    }
}

// MARK: - Bandeau de synthèse (dernières valeurs)
struct LatestReadingsView: View {
    let latest: MeasurementRecord

    var body: some View {
        HStack(spacing: 12) {
            metricBox(title: "CO₂", value: "\(latest.co2)", unit: "ppm", color: co2Color(latest.co2))
            metricBox(title: "Temp.", value: String(format: "%.1f", latest.temperature), unit: "°C", color: tempColor(latest.temperature))
            metricBox(title: "Hum.", value: String(format: "%.1f", latest.humidity), unit: "%", color: .blue)
            metricBox(title: "Press.", value: String(format: "%.0f", latest.pressure), unit: "hPa", color: .white)
            Spacer()
        }
    }

    private func metricBox(title: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func co2Color(_ ppm: Int) -> Color {
        if ppm < 1000 { return .green }
        if ppm < 1400 { return .yellow }
        return .red
    }

    private func tempColor(_ c: Double) -> Color {
        if c > 30 { return .red }
        if c < 10 { return .cyan }
        return .orange
    }
}

// MARK: - Explorateur de fichiers CSV

/// Vue affichant la liste des fichiers CSV enregistrés dans le dossier de logs et permettant de les consulter ou de les supprimer.
struct CSVExplorerView: View {
    @ObservedObject var storage: HistoryStorage
    // Liste des URL des fichiers CSV présents dans le répertoire de logs
    @State private var files: [URL] = []
    // Contenu du fichier actuellement affiché
    @State private var contentString: String = ""
    // Afficher la feuille de contenu
    @State private var showContent: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fichiers CSV d'historique")
                .font(.title3).bold()
            List {
                ForEach(files, id: \ .self) { file in
                    HStack {
                        Text(file.lastPathComponent)
                        Spacer()
                        Button("Afficher") {
                            if let c = try? String(contentsOf: file, encoding: .utf8) {
                                contentString = c
                                showContent = true
                            }
                        }
                        .buttonStyle(.borderless)
                        Button("Supprimer", role: .destructive) {
                            try? FileManager.default.removeItem(at: file)
                            loadFiles()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 300)
            .onAppear { loadFiles() }
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .sheet(isPresented: $showContent) {
            ScrollView {
                Text(contentString)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .frame(minWidth: 500, minHeight: 400)
        }
    }

    /// Charge la liste des fichiers présents dans le répertoire de logs CSV.
    private func loadFiles() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: storage.csvLogDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        self.files = urls.filter { $0.pathExtension.lowercased() == "csv" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }
}

// MARK: - Feuille de suppression par plage

/// Vue permettant de sélectionner une plage de dates à supprimer dans l'historique et demandant une double confirmation.
struct DeleteRangeSheet: View {
    @ObservedObject var storage: HistoryStorage
    let deviceID: UUID?
    @Binding var initialStart: Date
    @Binding var initialEnd: Date
    @Binding var isPresented: Bool
    @State private var confirmStage: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supprimer une plage de l'historique")
                .font(.headline)
            DatePicker("Début", selection: $initialStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Fin", selection: $initialEnd, displayedComponents: [.date, .hourAndMinute])
            if confirmStage == 0 {
                HStack {
                    Button("Annuler") { isPresented = false }
                    Spacer()
                    Button("Continuer", role: .destructive) {
                        confirmStage = 1
                    }
                }
            } else {
                Text("Cette action supprimera définitivement les mesures comprises dans cette plage.")
                    .foregroundColor(.red)
                HStack {
                    Button("Annuler") { isPresented = false }
                    Spacer()
                    Button("Supprimer", role: .destructive) {
                        let range = initialStart...initialEnd
                        Task { @MainActor in
                            storage.deleteRecords(in: range, for: deviceID)
                        }
                        isPresented = false
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

// MARK: - macOS Window Accessor Helper
#if os(macOS)
import Cocoa
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
