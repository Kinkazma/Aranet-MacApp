import Foundation

/// Classe responsable du stockage persistant des mesures et de la gestion des logs CSV.
/// Cette implémentation conserve une liste en mémoire pour l'affichage et écrit des fichiers
/// CSV séparés lors de chaque synchronisation automatique.  Elle expose également un
/// fichier CSV complet qui contient l'intégralité des mesures accumulées.
@MainActor
class HistoryStorage: ObservableObject {
    /// Liste triée de toutes les mesures connues.
    @Published private(set) var records: [MeasurementRecord] = []

    /// Registre des mesures classées par identifiant d'appareil.
    /// Lorsque des mesures sont insérées avec un identifiant d'appareil précis,
    /// elles sont également regroupées dans ce dictionnaire afin de permettre
    /// un filtrage par appareil dans l’interface utilisateur.  Les clés du
    /// dictionnaire correspondent aux identifiants uniques des appareils et les
    /// valeurs sont des tableaux de mesures déjà normalisées et dédupliquées.
    @Published var recordsByDevice: [UUID: [MeasurementRecord]] = [:]
    /// Dernier enregistrement fiable (liste triée ascendente).
    var latestRecord: MeasurementRecord? {
        return records.max(by: { $0.timestamp < $1.timestamp })
    }
    /// Répertoire dans lequel les CSV intermédiaires sont enregistrés.
    let csvLogDirectoryURL: URL
    /// Fichier CSV complet pour l'historique agrégé.
    let fullHistoryURL: URL

    init() {
        // Déterminer un répertoire d'application dans Application Support
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Aranet4MacApp", isDirectory: true)
        let logsDir = baseDir.appendingPathComponent("CSVLogs", isDirectory: true)
        let fullHistory = baseDir.appendingPathComponent("history_full.csv", isDirectory: false)
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        self.csvLogDirectoryURL = logsDir
        self.fullHistoryURL = fullHistory
        // Charger l'historique complet s'il existe
        if let data = try? String(contentsOf: fullHistory, encoding: .utf8) {
            let loaded = CSVManager.parseCSV(data)
            self.records = Self.normalizeAndDedup(loaded)
        }
    }

    // MARK: - Suppression / Édition de l'historique

    /// Supprime complètement toutes les mesures en mémoire ainsi que les fichiers CSV associés.
    /// Appelée lorsqu'une suppression totale est confirmée par l'utilisateur.
    @MainActor
    func deleteAllRecords() {
        // Vider les collections en mémoire
        records.removeAll()
        recordsByDevice.removeAll()
        // Supprimer le fichier d'historique complet
        let fm = FileManager.default
        if fm.fileExists(atPath: fullHistoryURL.path) {
            try? fm.removeItem(at: fullHistoryURL)
        }
        // Supprimer tous les logs CSV intermédiaires
        if let items = try? fm.contentsOfDirectory(at: csvLogDirectoryURL, includingPropertiesForKeys: nil) {
            for url in items {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Supprime sélectivement les mesures comprises dans une plage de dates donnée.
    /// - Parameters:
    ///   - range: Plage fermée de dates à supprimer.
    ///   - device: Optionnellement, l'identifiant de l'appareil dont l'historique doit être purgé.  Si `nil`, tous les appareils sont concernés.
    @MainActor
    func deleteRecords(in range: ClosedRange<Date>, for device: UUID?) {
        // Supprimer des listes par appareil
        if let devID = device {
            if var list = recordsByDevice[devID] {
                list.removeAll { range.contains($0.timestamp) }
                recordsByDevice[devID] = list
            }
        } else {
            // Supprimer dans toutes les listes par appareil
            for key in recordsByDevice.keys {
                recordsByDevice[key]?.removeAll { range.contains($0.timestamp) }
            }
        }
        // Recalculer la liste globale à partir des valeurs par appareil
        let all = recordsByDevice.values.flatMap { $0 }
        records = Self.normalizeAndDedup(all)
        // Écrire la nouvelle version du CSV complet
        do {
            _ = try CSVManager.export(records: records, to: fullHistoryURL)
        } catch {
            print("Erreur lors de la mise à jour de l'historique complet après suppression: \(error)")
        }
    }

    /// [Déprécié] : Utiliser `insert(records:for:)`. Conserve la compatibilité avec l'existant.
    func add(records newRecords: [MeasurementRecord]) {
        insert(records: newRecords, for: nil)
    }

    /// Insère des mesures en normalisant les dates (UTC, arrondi à la seconde) et en dédupliquant.
    /// `device` est accepté dès maintenant pour préparer le multi-appareils (étape 6), mais n'est pas encore utilisé.
    @MainActor
    func insert(records newRecords: [MeasurementRecord], for device: UUID?) {
        guard !newRecords.isEmpty else { return }

        // Normaliser toutes les entrées (arrondi seconde) pour éviter les doublons millisecondes
        let normalizedIncoming = newRecords.map(Self.normalizeRecord(_:))

        // Construire un index rapide des timestamps (à la seconde) existants
        var existingKeys = Set(records.map { Self.secondKey($0.timestamp) })

        // Fusion/dédup — en cas de conflit, on remplace l'ancien par le nouveau (incoming prioritaire)
        for rec in normalizedIncoming {
            let key = Self.secondKey(rec.timestamp)
            if let idx = records.firstIndex(where: { Self.secondKey($0.timestamp) == key }) {
                records[idx] = rec
            } else if !existingKeys.contains(key) {
                records.append(rec)
                existingKeys.insert(key)
            }
        }

        // Tri chronologique ascendant
        records.sort { $0.timestamp < $1.timestamp }

        // Enregistrer également les mesures par appareil si l'identifiant est fourni.
        if let devID = device {
            // Ajouter puis normaliser/dédupliquer la liste pour cet appareil
            var perDevice = recordsByDevice[devID] ?? []
            perDevice.append(contentsOf: normalizedIncoming)
            // Normaliser et dédupliquer pour l'appareil en question
            perDevice = Self.normalizeAndDedup(perDevice)
            recordsByDevice[devID] = perDevice
        }

        // Mettre à jour le CSV complet
        do {
            _ = try CSVManager.export(records: records, to: fullHistoryURL)
        } catch {
            print("Erreur lors de la mise à jour de l'historique complet: \(error)")
        }
    }
    /// Supprime toutes les mesures associées à un appareil donné.
    @MainActor
    func removeAll(for deviceID: UUID) {
        // Supprimer les mesures pour cet appareil
        recordsByDevice.removeValue(forKey: deviceID)
        // Recalculer la liste globale à partir des autres appareils restants
        let all = recordsByDevice.values.flatMap { $0 }
        records = Self.normalizeAndDedup(all)
        // Réécrire le CSV complet
        do {
            _ = try CSVManager.export(records: records, to: fullHistoryURL)
        } catch {
            print("Erreur lors de la mise à jour du CSV après suppression de l'appareil: \(error)")
        }
    }
    // MARK: - Normalisation & Déduplication

    /// Arrondit la date à la seconde (UTC) et renvoie un enregistrement normalisé.
    private static func normalizeRecord(_ r: MeasurementRecord) -> MeasurementRecord {
        // `Date` est absolue (UTC). On arrondit à la seconde pour toutes les opérations de clé/dédup.
        let ts = Date(timeIntervalSince1970: floor(r.timestamp.timeIntervalSince1970))
        return MeasurementRecord(timestamp: ts,
                                 co2: r.co2,
                                 temperature: r.temperature,
                                 humidity: r.humidity,
                                 pressure: r.pressure)
    }

    /// Déduplique par timestamp (seconde) en conservant le dernier exemplaire rencontré.
    private static func normalizeAndDedup(_ list: [MeasurementRecord]) -> [MeasurementRecord] {
        var dict: [Int64: MeasurementRecord] = [:]
        for item in list {
            let n = normalizeRecord(item)
            dict[secondKey(n.timestamp)] = n
        }
        return Array(dict.values).sorted { $0.timestamp < $1.timestamp }
    }

    /// Clé à la seconde pour l'index/dédup.
    private static func secondKey(_ date: Date) -> Int64 {
        return Int64(floor(date.timeIntervalSince1970))
    }

    /// Crée un fichier CSV contenant l'ensemble des nouvelles mesures et le sauvegarde dans le répertoire des logs.
    /// Le nom du fichier est basé sur la date de l'export.
    /// - Returns: l'URL du fichier créé.
    @discardableResult
    func saveLog(for newRecords: [MeasurementRecord]) throws -> URL {
        guard !newRecords.isEmpty else { throw NSError(domain: "HistoryStorage", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aucune donnée à enregistrer"]) }
        let formatter = ISO8601DateFormatter()
        let fileName = "aranet4_log_\(formatter.string(from: Date())).csv"
        let fileURL = csvLogDirectoryURL.appendingPathComponent(fileName)
        _ = try CSVManager.export(records: newRecords, to: fileURL)
        return fileURL
    }
}
