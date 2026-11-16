import Foundation

/// Fragt Jev über den Server (App und Widget gleich) und merkt sich die letzte
/// Antwort je Ort im App-Group-Container. Jeder Fehler heißt: Regeln entscheiden.
enum JevClient {
    static func decide(_ forecast: Forecast, ref: PlaceRef, placeName: String, at now: Date,
                       baseline: ForecastDigest? = nil, api: API = API()) async -> JevDecision? {
        let request = DecisionRequest.make(forecast, placeName: placeName, at: now, baseline: baseline)
        do {
            let decision = try await api.decide(request)
            DecisionCache.store(decision, for: ref)
            return decision
        } catch APIError.server(503, _) {
            // Auf dem Server nicht eingerichtet: kein alter Stand.
            DecisionCache.remove(ref)
            return nil
        } catch {
            // Offline oder Jev gestört: die letzte Antwort; die Reihenfolge gilt nur,
            // wenn sie zu denselben Hinweisen passt.
            return DecisionCache.load(ref)
        }
    }
}

extension API {
    func decide(_ request: DecisionRequest) async throws -> JevDecision {
        let body = try JSONEncoder().encode(request)
        let data = try await send("POST", "/api/v1/decide", body: body)
        return try JSONDecoder().decode(JevDecision.self, from: data)
    }
}

enum DecisionCache {
    private static func url(_ ref: PlaceRef) -> URL {
        ForecastCache.directory.appendingPathComponent("jev2-\(ref.cacheKey).json")
    }

    static func store(_ decision: JevDecision, for ref: PlaceRef) {
        guard let data = try? JSONEncoder().encode(decision) else { return }
        try? data.write(to: url(ref), options: .atomic)
    }

    static func load(_ ref: PlaceRef) -> JevDecision? {
        guard let data = try? Data(contentsOf: url(ref)) else { return nil }
        return try? JSONDecoder().decode(JevDecision.self, from: data)
    }

    static func remove(_ ref: PlaceRef) {
        try? FileManager.default.removeItem(at: url(ref))
    }
}

/// Kurzfassungen früherer Vorhersagen je Ort, für „Vorhersage geändert“. Nicht für
/// „Mein Standort“: Nach einem Ortswechsel wäre der Vergleich irreführend.
enum DigestStore {
    private static func url(_ ref: PlaceRef) -> URL {
        ForecastCache.directory.appendingPathComponent("digests-\(ref.cacheKey).json")
    }

    static func history(_ ref: PlaceRef) -> [ForecastDigest] {
        guard let data = try? Data(contentsOf: url(ref)) else { return [] }
        return (try? JSONDecoder().decode([ForecastDigest].self, from: data)) ?? []
    }

    static func record(_ forecast: Forecast, for ref: PlaceRef) {
        guard ref != .current else { return }
        let updated = ForecastDigest.appending(ForecastDigest(forecast), to: history(ref))
        guard let data = try? JSONEncoder().encode(updated) else { return }
        try? data.write(to: url(ref), options: .atomic)
    }

    static func baseline(_ ref: PlaceRef, now: Date) -> ForecastDigest? {
        guard ref != .current else { return nil }
        return ForecastDigest.baseline(in: history(ref), now: now)
    }

    static func remove(_ ref: PlaceRef) {
        try? FileManager.default.removeItem(at: url(ref))
    }
}
