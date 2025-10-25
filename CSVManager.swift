import Foundation

/// Utilitaire statique pour gérer l'import et l'export de fichiers CSV contenant des mesures.
enum CSVManager {
    // MARK: - Export

    static func export(records: [MeasurementRecord], fileName: String) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documents.appendingPathComponent(fileName)
        return try export(records: records, to: url)
    }

    static func export(records: [MeasurementRecord], to url: URL) throws -> URL {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        let header = "date,co2,temperature,humidity,pressure"
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var rows: [String] = [header]
        rows.reserveCapacity(sorted.count + 1)
        for record in sorted {
            let dateStr = formatter.string(from: record.timestamp)
            let line = "\(dateStr),\(record.co2),\(format(record.temperature, digits: 2)),\(format(record.humidity, digits: 2)),\(format(record.pressure, digits: 2))"
            rows.append(line)
        }
        let csvString = rows.joined(separator: "\n")
        try csvString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func export(records: [MeasurementRecord], in range: ClosedRange<Date>, to url: URL) throws -> URL {
        let filtered = records.filter { range.contains($0.timestamp) }
        return try export(records: filtered, to: url)
    }

    static func export(records: [MeasurementRecord], in range: ClosedRange<Date>, fileName: String) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documents.appendingPathComponent(fileName)
        return try export(records: records, in: range, to: url)
    }

    // MARK: - Import

    static func parseCSV(_ text: String) -> [MeasurementRecord] {
        return parseCSV(text, logPrefix: nil).records
    }

    static func parseCSVWithReport(_ text: String, logPrefix: String? = nil) -> (records: [MeasurementRecord], errors: Int, warnings: Int) {
        return parseCSV(text, logPrefix: logPrefix)
    }

    private static func parseCSV(_ text: String, logPrefix: String?) -> (records: [MeasurementRecord], errors: Int, warnings: Int) {
        var errors = 0
        var warnings = 0

        var lines = text.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = lines.popLast() }
        guard !lines.isEmpty else { return ([], 0, 0) }

        var headerLine = lines.removeFirst()
        if headerLine.hasPrefix("\u{FEFF}") { headerLine.removeFirst() }

        let sep = detectSeparator(in: headerLine) ?? (lines.first.flatMap(detectSeparator) ?? ",")
        let headers = splitCSVLine(headerLine, separator: sep).map(normalizeHeader)

        // mapping (FR officiel de l'app Aranet pris en charge)
        var dateIdx      = index(of: ["date","timestamp","time","datetime","iso","iso8601","epoch","epoch_s","epoch_ms"], in: headers)
        var co2Idx       = index(of: ["co2","co2ppm","ppm","dioxydecarbone","dioxdedecarbone","carbone"], in: headers)
        var tempIdx      = index(of: ["temperature","temp","t","temperaturec","degc","°c","temperature°c","temperaturecelsius"], in: headers)
        var humidityIdx  = index(of: ["humidity","hum","rh","relativehumidity","humiditerelative"], in: headers)
        var pressureIdx  = index(of: ["pressure","press","baro","barometricpressure","pressurehpa","hpa","pressionatmospherique"], in: headers)

        let tempUnit     = unitHint(from: headers[safe: tempIdx])
        let humidityUnit = unitHint(from: headers[safe: humidityIdx])
        let pressureUnit = unitHint(from: headers[safe: pressureIdx])

        var out: [MeasurementRecord] = []
        out.reserveCapacity(lines.count)

        // Fallback « 5 colonnes » si en‑têtes non reconnus
        let fallbackFiveCols = (dateIdx == nil || co2Idx == nil || tempIdx == nil || humidityIdx == nil || pressureIdx == nil)
            && splitCSVLine(headerLine, separator: sep).count == 5
        if fallbackFiveCols {
            dateIdx = 0; co2Idx = 1; tempIdx = 2; humidityIdx = 3; pressureIdx = 4
        }

        for (lineNumber, rawLine) in lines.enumerated() {
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cols = splitCSVLine(rawLine, separator: sep)

            func warn(_ msg: String) {
                warnings += 1
                if let p = logPrefix { print("[CSV][WARN][\(p)] line \(lineNumber+2): \(msg)") }
            }
            func fail(_ msg: String) {
                errors += 1
                if let p = logPrefix { print("[CSV][ERROR][\(p)] line \(lineNumber+2): \(msg)") }
            }

            guard let dIdx = dateIdx, dIdx < cols.count else { fail("Colonne date manquante"); continue }
            let dateVal = cols[dIdx].trimmingCharacters(in: .whitespaces)
            guard let date = parseDate(dateVal) else {
                // format FR de l’app officielle
                if let d = parseFRDate(dateVal) { 
                    // converti en Date locale -> on normalise en UTC en sortie (Date est UTC par nature)
                    processRow(cols: cols, d: d, co2Idx: co2Idx, tempIdx: tempIdx, humidityIdx: humidityIdx, pressureIdx: pressureIdx, tempUnit: tempUnit, humidityUnit: humidityUnit, pressureUnit: pressureUnit, out: &out, warn: warn)
                    continue
                }
                fail("Date invalide: \(dateVal)"); continue
            }

            processRow(cols: cols, d: date, co2Idx: co2Idx, tempIdx: tempIdx, humidityIdx: humidityIdx, pressureIdx: pressureIdx, tempUnit: tempUnit, humidityUnit: humidityUnit, pressureUnit: pressureUnit, out: &out, warn: warn)
        }

        return (out, errors, warnings)
    }

    private static func processRow(cols: [String], d: Date, co2Idx: Int?, tempIdx: Int?, humidityIdx: Int?, pressureIdx: Int?, tempUnit: String?, humidityUnit: String?, pressureUnit: String?, out: inout [MeasurementRecord], warn: (String)->Void) {
        guard let cIdx = co2Idx, cIdx < cols.count, let co2 = Int(cols[cIdx].filter { !$0.isWhitespace }) else { warn("CO₂ manquant/invalid → ligne ignorée"); return }

        guard let tIdx = tempIdx, tIdx < cols.count, let tRaw = Double(cols[tIdx].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { warn("Temp manquante/invalid → ligne ignorée"); return }
        guard let hIdx = humidityIdx, hIdx < cols.count, let hRaw = Double(cols[hIdx].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { warn("Hum manquante/invalid → ligne ignorée"); return }
        guard let pIdx = pressureIdx, pIdx < cols.count, let pRaw = Double(cols[pIdx].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { warn("Press manquante/invalid → ligne ignorée"); return }

        let tempC = normalizeTemperature(tRaw, hint: tempUnit)
        let humPct = normalizeHumidity(hRaw, hint: humidityUnit)
        let presHpa = normalizePressure(pRaw, hint: pressureUnit)

        out.append(MeasurementRecord(timestamp: d, co2: co2, temperature: tempC, humidity: humPct, pressure: presHpa))
    }

    // MARK: - Helpers

    private static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func detectSeparator(in line: String) -> Character? {
        let candidates: [Character] = [",",";","\t"]
        let counts = candidates.map { ch in (ch, line.reduce(0) { $1 == ch ? $0+1 : $0 }) }
        return counts.max(by: { $0.1 < $1.1 })?.0
    }

    private static func splitCSVLine(_ line: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                if inQuotes, i < line.index(before: line.endIndex), line[line.index(after: i)] == "\"" {
                    current.append("\"")
                    i = line.index(after: i)
                } else { inQuotes.toggle() }
            } else if ch == separator && !inQuotes {
                out.append(current); current.removeAll(keepingCapacity: true)
            } else { current.append(ch) }
            i = line.index(after: i)
        }
        out.append(current)
        return out.map { s in
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t.removeFirst(); t.removeLast() }
            return t
        }
    }

    private static func normalizeHeader(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // strip accents/diacritics
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        // remove punctuation/spaces
        let remove: [String] = [" ", "-", "_", "(", ")", ",", "."]
        for ch in remove { s = s.replacingOccurrences(of: ch, with: "") }
        // normalize known french headers to english tokens
        // date/time
        if s.contains("timedd/mm/yyyy") || s.contains("time") { s = s.replacingOccurrences(of: "timedd/mm/yyyyh:mm:ss", with: "date") }
        if s.contains("datetime") { s = s.replacingOccurrences(of: "datetime", with: "date") }
        // co2
        if s.contains("dioxyde") || s.contains("carbone") { s = "co2ppm" }
        s = s.replacingOccurrences(of: "co₂", with: "co2")
        // temperature
        if s.contains("temperature") { s = s.replacingOccurrences(of: "temperature", with: "temperature") }
        // humidity
        if s.contains("humidite") { s = "humidity" }
        // pressure
        if s.contains("pression") { s = s.replacingOccurrences(of: "pressionatmospherique", with: "pressurehpa") }
        // finally compact common english forms
        s = s.replacingOccurrences(of: "relativehumidity", with: "humidity")
        s = s.replacingOccurrences(of: "barometricpressure", with: "pressure")
        s = s.replacingOccurrences(of: "iso8601", with: "iso")
        return s
    }

    private static func index(of candidates: [String], in headers: [String]) -> Int? {
        for (i, h) in headers.enumerated() {
            if candidates.contains(where: { h.hasPrefix($0) }) { return i }
        }
        return nil
    }

    private static func unitHint(from header: String?) -> String? {
        guard let h = header else { return nil }
        if h.contains("kpa") { return "kpa" }
        if h.contains("hpa") { return "hpa" }
        if h == "pa" || h.contains("pa") { return "pa" }
        if h.hasSuffix("f") { return "f" }
        if h.contains("degf") { return "f" }
        if h.contains("degc") || h.hasSuffix("c") { return "c" }
        if h.contains("percent") || h.contains("pct") { return "%" }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let num = Double(trimmed) {
            if num > 100_000_000_000 { return Date(timeIntervalSince1970: num / 1000.0) } else { return Date(timeIntervalSince1970: num) }
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        let fmts = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "dd/MM/yyyy H:mm:ss",
            "dd/MM/yyyy H:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for f in fmts { df.dateFormat = f; if let d = df.date(from: trimmed) { return d } }
        return nil
    }

    private static func parseFRDate(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.timeZone = TimeZone.current
        df.dateFormat = "dd/MM/yyyy H:mm:ss"
        return df.date(from: s)
    }

    private static func normalizeTemperature(_ value: Double, hint: String?) -> Double {
        if hint == "f" { return (value - 32.0) * 5.0 / 9.0 }
        return value
    }

    private static func normalizeHumidity(_ value: Double, hint: String?) -> Double {
        if value >= 0.0, value <= 1.0 { return value * 100.0 }
        return value
    }

    private static func normalizePressure(_ value: Double, hint: String?) -> Double {
        if let h = hint {
            if h == "kpa" { return value * 10.0 }
            if h == "pa"  { return value / 100.0 }
            if h == "hpa" { return value }
        }
        if value < 20.0 { return value * 10.0 }
        return value
    }
}

private extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let idx = index, indices.contains(idx) else { return nil }
        return self[idx]
    }
}
