import Foundation

/// Asks an OpenAI-compatible server which models it offers (`GET <base>/models`), so a custom setup can pick one
/// instead of typing its exact name. Sends only the key (if any); no question or screen content.
enum ModelListFetcher {
    enum Failure: Error, Equatable {
        case badAddress, rejectedKey, unreachable, unexpectedReply
        var message: String {
            switch self {
            case .badAddress: return "That address isn't valid. It usually ends in /v1."
            case .rejectedKey: return "The server didn't accept the key."
            case .unreachable: return "Couldn't reach that server. Check the address and that it's running."
            case .unexpectedReply: return "The server answered, but not with a list of models. Type the model name instead."
            }
        }
    }

    static func fetch(baseURL: String, key: String?) async throws -> [String] {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = base.scheme?.lowercased(), scheme == "https" || scheme == "http", base.host?.isEmpty == false else {
            throw Failure.badAddress
        }
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 10)
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.rejectedKey }
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedReply
        }
        // OpenAI style {"data":[{"id":…}]}; some servers use {"models":[{"name"|"id":…}]}.
        let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        let ids = entries.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        guard !ids.isEmpty else { throw Failure.unexpectedReply }
        return Array(Set(ids)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
