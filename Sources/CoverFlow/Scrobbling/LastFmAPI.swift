import Foundation
import CryptoKit

struct LastFmCredentials: Codable, Equatable {
    var apiKey: String
    var secret: String
    var sessionKey: String = ""
    var username: String = ""
    var configured: Bool { !apiKey.isEmpty && !secret.isEmpty }
    var connected: Bool { configured && !sessionKey.isEmpty && !username.isEmpty }
}

struct LastFmAPIError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
    var retryable: Bool { [11, 16, 29].contains(code) || code >= 500 }
}

struct LastFmReply: Decodable {
    struct Session: Decodable { let name: String; let key: String }
    struct Scrobbles: Decodable {
        let accepted: String
        let ignored: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let attributes = try? c.decode([String: String].self, forKey: .attributes) {
                accepted = attributes["accepted"] ?? "0"
                ignored = attributes["ignored"] ?? "0"
            } else {
                accepted = try (try? c.decode(String.self, forKey: .accepted)) ?? String(c.decode(Int.self, forKey: .accepted))
                ignored = try (try? c.decode(String.self, forKey: .ignored)) ?? String(c.decode(Int.self, forKey: .ignored))
            }
        }
        enum CodingKeys: String, CodingKey { case accepted, ignored; case attributes = "@attr" }
    }
    let token: String?
    let session: Session?
    let error: Int?
    let message: String?
    let scrobbles: Scrobbles?
}

final class LastFmAPI {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func signature(_ parameters: [String: String], secret: String) -> String {
        let text = parameters.keys.filter { $0 != "format" && $0 != "callback" && $0 != "api_sig" }.sorted()
            .map { $0 + parameters[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func request(method: String, parameters: [String: String], credentials: LastFmCredentials) -> URLRequest {
        var fields = parameters
        fields["method"] = method
        fields["api_key"] = credentials.apiKey
        if !credentials.sessionKey.isEmpty { fields["sk"] = credentials.sessionKey }
        fields["api_sig"] = signature(fields, secret: credentials.secret)
        fields["format"] = "json"
        // Form bodies need literal '+' escaped, including in artist/title names.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.keys.sorted().map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    func call(_ method: String, parameters: [String: String] = [:], credentials: LastFmCredentials) async throws -> LastFmReply {
        let (data, response) = try await session.data(for: Self.request(method: method, parameters: parameters, credentials: credentials))
        let reply = try? JSONDecoder().decode(LastFmReply.self, from: data)
        if let code = reply?.error { throw LastFmAPIError(code: code, message: reply?.message ?? "Last.fm rejected the request.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmAPIError(code: (response as? HTTPURLResponse)?.statusCode ?? 503, message: "Last.fm is unavailable. Try again later.")
        }
        guard let reply else { throw LastFmAPIError(code: 503, message: "Last.fm returned an unreadable response.") }
        return reply
    }
}
