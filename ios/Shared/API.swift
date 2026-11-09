import Foundation

enum APIError: LocalizedError, Equatable {
    case notSignedIn
    case unauthorized
    case server(status: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Nicht angemeldet."
        case .unauthorized: "Die Anmeldung ist abgelaufen. Bitte neu anmelden."
        case let .server(status, message): message.isEmpty ? "Serverfehler \(status)" : message
        case let .keychain(status): "Schlüsselbund-Fehler \(status)"
        }
    }
}

/// Aufrufe gegen docs/api.md. Ohne Zustand: Server und Token kommen bei jedem
/// Aufruf frisch aus `SharedStore`/`TokenStore`, damit App und Widget gleich arbeiten.
struct API: Sendable {
    var baseURL: URL = SharedStore.serverURL
    var session: URLSession = .shared

    /// Der Dev-Server nimmt über localhost unangemeldete Anfragen an.
    static func needsAuth(_ url: URL) -> Bool {
        !["localhost", "127.0.0.1", "::1"].contains(url.host() ?? "")
    }

    var needsAuth: Bool { Self.needsAuth(baseURL) }

    // MARK: Endpunkte

    func places() async throws -> [Place] {
        try await JSONDecoder.api.decode([Place].self, from: send("GET", "/api/v1/places"))
    }

    func addPlace(name: String, lat: Double, lon: Double) async throws -> Place {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "lat": lat, "lon": lon])
        return try await JSONDecoder.api.decode(Place.self, from: send("POST", "/api/v1/places", body: body))
    }

    func updatePlace(_ id: Int, _ changes: [String: any Sendable]) async throws -> Place {
        let body = try JSONSerialization.data(withJSONObject: changes)
        return try await JSONDecoder.api.decode(Place.self, from: send("PATCH", "/api/v1/places/\(id)", body: body))
    }

    func deletePlace(_ id: Int) async throws {
        _ = try await send("DELETE", "/api/v1/places/\(id)")
    }

    /// Liefert die Vorhersage und die rohen Bytes für den Cache.
    func forecast(_ ref: PlaceRef, lat: Double? = nil, lon: Double? = nil) async throws -> (Forecast, Data) {
        let data: Data
        switch ref {
        case let .saved(id):
            data = try await send("GET", "/api/v1/places/\(id)/forecast")
        case .current:
            // Auf 0,02° gerundet fragt der Server ohnehin ab; hier reichen vier Stellen.
            let query = [URLQueryItem(name: "lat", value: String(format: "%.4f", lat ?? 0)),
                         URLQueryItem(name: "lon", value: String(format: "%.4f", lon ?? 0))]
            data = try await send("GET", "/api/v1/forecast", query: query)
        }
        return (try JSONDecoder.api.decode(Forecast.self, from: data), data)
    }

    func radar() async throws -> RadarInfo {
        try await JSONDecoder.api.decode(RadarInfo.self, from: send("GET", "/api/v1/radar"))
    }

    func exchangeCode(_ code: String, verifier: String) async throws -> String {
        struct TokenResponse: Decodable { let token: String }
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
        return try await JSONDecoder.api.decode(TokenResponse.self, from: send("POST", "/auth/device/token", body: body, authorized: false)).token
    }

    // MARK: Transport

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, authorized: Bool = true) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("ios", forHTTPHeaderField: "X-Witterung-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized, needsAuth {
            guard let token = TokenStore.token else { throw APIError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Vertrag: 401 → Token verwerfen, neu anmelden.
            if authorized, needsAuth { TokenStore.delete() }
            throw APIError.unauthorized
        }
        guard (200..<300).contains(status) else {
            struct Envelope: Decodable { struct Body: Decodable { let message: String }; let error: Body }
            let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error.message ?? ""
            throw APIError.server(status: status, message: message)
        }
        return data
    }
}
