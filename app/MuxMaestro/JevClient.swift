import Foundation

/// Sends one request and hands back the body and status code. `URLSession` in
/// the app; tests record the request and answer it by hand.
protocol HTTPTransport {
    func send(_ request: URLRequest, completion: @escaping (Result<(Data, Int), Error>) -> Void)
}

struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest, completion: @escaping (Result<(Data, Int), Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(.success((data ?? Data(), status)))
        }.resume()
    }
}

/// One question for jev. A choice question names its options, each with an
/// optional sentence for when it applies; a boolean question is answered with
/// P(true).
enum JevQuestion: Encodable, Equatable {
    case choice(instructions: String, options: [String: String?])
    case boolean(instructions: String)

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let instructions, let options):
            try c.encode("choice", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(options, forKey: .criteria)
        case .boolean(let instructions):
            try c.encode("boolean", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
        }
    }
}

/// One answer. Choice answers carry the distribution over the options; boolean
/// answers carry P(true), not confidence in either outcome.
enum JevAnswer: Decodable, Equatable {
    case choice(String, probabilities: [String: Double])
    case score(Double)
    case boolean(Double)

    private enum CodingKeys: String, CodingKey { case type, choice, probabilities, score, probability }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "choice":
            self = .choice(
                try c.decode(String.self, forKey: .choice),
                probabilities: try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:])
        case "score":
            self = .score(try c.decode(Double.self, forKey: .score))
        case "boolean":
            self = .boolean(try c.decode(Double.self, forKey: .probability))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown answer type \(other)")
        }
    }

    /// P(true) of a boolean answer; nil for any other kind.
    var probability: Double? {
        if case .boolean(let p) = self { return p }
        return nil
    }

    /// The probability of `option` in a choice answer; nil for any other kind.
    func probability(of option: String) -> Double? {
        if case .choice(_, let probabilities) = self { return probabilities[option] ?? 0 }
        return nil
    }
}

struct JevResponse: Decodable, Equatable {
    struct Usage: Decodable, Equatable {
        let inputTokens: Int?
        let outputTokens: Int?
    }

    struct ProviderMetadata: Decodable, Equatable {
        struct Gateway: Decodable, Equatable {
            /// What the gateway charged, as a decimal string.
            let marketCost: String?
        }
        let gateway: Gateway?
    }

    let answers: [String: JevAnswer]
    let usage: Usage?
    let providerMetadata: ProviderMetadata?
}

enum JevError: Error, Equatable {
    /// 401/403: the key is wrong or has no AI Gateway access.
    case unauthorized(String)
    case http(Int, String)
    case transport(String)
    case badResponse

    var message: String {
        switch self {
        case .unauthorized(let m): return m
        case .http(let code, let m): return m.isEmpty ? "HTTP \(code)" : m
        case .transport(let m): return m
        case .badResponse: return "Unexpected response from AI Gateway."
        }
    }
}

/// Asks `typesafe-ai/jev` typed questions about a state through the Vercel AI
/// Gateway's evaluation-model endpoint, the one `@ai-sdk/gateway` posts to. One
/// call answers every question.
struct JevClient {
    static let endpoint = URL(string: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model")!
    static let modelId = "typesafe-ai/jev"

    let key: String
    var transport: HTTPTransport = URLSessionTransport()

    private struct Body<State: Encodable>: Encodable {
        let state: State
        let questions: [String: JevQuestion]
    }

    func request<State: Encodable>(
        state: State, questions: [String: JevQuestion]
    ) throws -> URLRequest {
        var r = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
        r.setValue("4", forHTTPHeaderField: "ai-evaluation-model-specification-version")
        r.setValue(Self.modelId, forHTTPHeaderField: "ai-model-id")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        r.httpBody = try encoder.encode(Body(state: state, questions: questions))
        return r
    }

    /// `completion` runs on the transport's queue.
    func evaluate<State: Encodable>(
        state: State, questions: [String: JevQuestion],
        completion: @escaping (Result<JevResponse, JevError>) -> Void
    ) {
        guard let request = try? request(state: state, questions: questions) else {
            return completion(.failure(.badResponse))
        }
        transport.send(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(.transport(error.localizedDescription)))
            case .success(let (data, status)):
                completion(Self.decode(data: data, status: status))
            }
        }
    }

    static func decode(data: Data, status: Int) -> Result<JevResponse, JevError> {
        guard (200..<300).contains(status) else {
            let message = errorMessage(data)
            return .failure(status == 401 || status == 403
                ? .unauthorized(message ?? "Authentication failed.")
                : .http(status, message ?? ""))
        }
        guard let response = try? JSONDecoder().decode(JevResponse.self, from: data) else {
            return .failure(.badResponse)
        }
        return .success(response)
    }

    /// The gateway's `{"error":{"message":…}}`, when the body is that shape.
    private static func errorMessage(_ data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }
}
