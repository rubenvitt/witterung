import Foundation

/// WMS-Kachel-URLs für das DWD-Radar (WMS 1.3.0, EPSG:3857).
enum WMSTile {
    static let earthHalf = 20_037_508.342789244

    /// Kachel x/y/z (XYZ-Schema, y von oben) → BBOX in Web-Mercator-Metern.
    static func bbox(x: Int, y: Int, z: Int) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let size = 2 * earthHalf / Double(1 << z)
        let minX = -earthHalf + Double(x) * size
        let maxY = earthHalf - Double(y) * size
        return (minX, maxY - size, minX + size, maxY)
    }

    static func url(base: URL, layer: String, time: Date, x: Int, y: Int, z: Int, pixels: Int = 512) -> URL {
        let b = bbox(x: x, y: y, z: z)
        var url = base
        url.append(queryItems: [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "LAYERS", value: layer),
            URLQueryItem(name: "STYLES", value: ""),
            // Bei EPSG:3857 ist die Achsenfolge auch in WMS 1.3.0 x,y.
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: [b.minX, b.minY, b.maxX, b.maxY].map { String(format: "%.2f", $0) }.joined(separator: ",")),
            URLQueryItem(name: "WIDTH", value: "\(pixels)"),
            URLQueryItem(name: "HEIGHT", value: "\(pixels)"),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "true"),
            URLQueryItem(name: "TIME", value: time.formatted(.iso8601)),
        ])
        return url
    }
}
