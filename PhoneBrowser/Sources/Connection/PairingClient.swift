import Foundation

enum PairingError: LocalizedError {
    case invalidRelayURL
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            "Enter the relay URL as http(s)://host:port."
        case .rejected(let status, let message):
            "Pairing failed (\(status)): \(message)"
        }
    }
}

/// Exchanges a short-lived one-time code, confirmed by the device owner, for
/// a device credential.
enum PairingClient {
    struct Response: Decodable {
        let deviceID: String
        let deviceToken: String

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case deviceToken
        }
    }

    static func pair(
        relayURLText: String,
        code: String,
        deviceName: String,
        urlSession: URLSession = .shared
    ) async throws -> DeviceCredential {
        guard let relayURL = URL(string: relayURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = relayURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
            relayURL.host != nil
        else {
            throw PairingError.invalidRelayURL
        }
        var request = URLRequest(url: relayURL.appending(path: "v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "deviceName": deviceName,
            "protocolVersion": PhoneBrowserProtocol.version,
        ])
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PairingError.rejected(status: status, message: message ?? "unexpected response")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return DeviceCredential(relayURL: relayURL, deviceID: decoded.deviceID, token: decoded.deviceToken)
    }
}
