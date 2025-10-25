import Foundation

/// Mesure unique provenant de l'Aranet4
struct MeasurementRecord: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let co2: Int           // ppm
    let temperature: Double// °C
    let humidity: Double   // %
    let pressure: Double   // hPa

    init(id: UUID = UUID(), timestamp: Date, co2: Int, temperature: Double, humidity: Double, pressure: Double) {
        self.id = id
        self.timestamp = timestamp
        self.co2 = co2
        self.temperature = temperature
        self.humidity = humidity
        self.pressure = pressure
    }
}
