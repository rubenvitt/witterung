import Foundation

/// Reine Rechnungen für die Radarkarte (ohne MapKit, damit die Logiktests sie mitkompilieren).
enum RadarGeometry {
    static let earthRadius = 6_378_137.0

    /// Web-Mercator-Meter (EPSG:3857) → Breite/Länge in Grad.
    static func coordinate(x: Double, y: Double) -> (lat: Double, lon: Double) {
        (lat: atan(sinh(y / earthRadius)) * 180 / .pi, lon: x / earthRadius * 180 / .pi)
    }

    /// Ecken der `bbox` (minX, minY, maxX, maxY): Nordwest und Südost in Grad.
    static func corners(_ bbox: [Double]) -> (northWest: (lat: Double, lon: Double), southEast: (lat: Double, lon: Double))? {
        guard bbox.count == 4, bbox[0] < bbox[2], bbox[1] < bbox[3] else { return nil }
        return (coordinate(x: bbox[0], y: bbox[3]), coordinate(x: bbox[2], y: bbox[1]))
    }

    /// Ladereihenfolge: zuerst das Bild, das gerade zu sehen ist, dann abwechselnd die
    /// nächsten danach und davor. So ist die Zeitleiste um „jetzt“ zuerst spielbar.
    static func loadOrder(count: Int, from start: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(start, 0), count - 1)
        var order = [start]
        for d in 1..<max(count, 1) {
            if start + d < count { order.append(start + d) }
            if start - d >= 0 { order.append(start - d) }
        }
        return order
    }

    /// Nächstes geladenes Bild nach `index` (im Kreis), für das Abspielen: Fehlende Bilder
    /// werden übersprungen statt eine leere Karte zu zeigen.
    static func nextLoaded(after index: Int, count: Int, isLoaded: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        for step in 1...count {
            let i = (index + step) % count
            if isLoaded(i) { return i }
        }
        return nil
    }
}
