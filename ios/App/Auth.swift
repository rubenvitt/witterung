import AuthenticationServices
import SwiftUI
import CryptoKit
import Foundation
import UIKit

/// PKCE nach RFC 7636 (S256).
enum PKCE {
    /// 32 Zufallsbytes, Base64URL → 43 Zeichen aus `[A-Za-z0-9-_]`.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Kein Zufall verfügbar")
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Geräte-Anmeldung aus docs/api.md: Browser → `witterung://auth?code=…` → Token.
enum DeviceSignIn {
    @MainActor
    static func run(server: URL, session: WebAuthenticationSession) async throws {
        let verifier = PKCE.makeVerifier()
        var start = server.appending(path: "/auth/device/start")
        start.append(queryItems: [
            URLQueryItem(name: "challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "name", value: UIDevice.current.name),
        ])
        let callback = try await session.authenticate(using: start, callbackURLScheme: "witterung", preferredBrowserSession: .shared)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw APIError.server(status: 0, message: "Anmeldung ohne Code zurückgekommen.") }
        let token = try await API(baseURL: server).exchangeCode(code, verifier: verifier)
        try TokenStore.save(token)
    }
}
