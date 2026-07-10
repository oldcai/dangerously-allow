import DangerouslyAllowCore
import Foundation

/// The one part of the fallback that touches the network: a concrete
/// `LLMAdjudicator` that labels a menu by calling the Messages API. The request
/// is built and the response parsed in `DangerouslyAllowCore` (both tested
/// there); this only moves bytes. There is no official Anthropic SDK for Swift,
/// so it is raw HTTP over URLSession, following the documented request shape.
struct NetworkAdjudicator: LLMAdjudicator {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let model: String
    private let timeout: TimeInterval
    private let auth: (header: String, value: String)
    private let oauth: Bool
    private let session: URLSession

    /// Resolves credentials the way the SDKs do: `ANTHROPIC_API_KEY` (sent as
    /// `x-api-key`), else `ANTHROPIC_AUTH_TOKEN` (a bearer token). Returns nil
    /// when neither is set, so the caller can disable the fallback and say why.
    init?(model: String, timeout: TimeInterval = 15) {
        let env = ProcessInfo.processInfo.environment
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
            auth = ("x-api-key", key)
            oauth = false
        } else if let token = env["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty {
            auth = ("authorization", "Bearer \(token)")
            oauth = true
        } else {
            return nil
        }
        self.model = model
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func judge(context: [String], options: [MenuRow]) throws -> PromptJudgment {
        guard let body = try? AdjudicatorAPI.encodedRequest(context: context, options: options, model: model) else {
            throw AdjudicatorError.malformedResponse("could not encode request")
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(auth.value, forHTTPHeaderField: auth.header)
        if oauth { req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = body

        // The watcher's poll loop is synchronous, so block on the round trip.
        let sem = DispatchSemaphore(value: 0)
        var result: Result<PromptJudgment, AdjudicatorError> =
            .failure(.transport("request did not complete"))
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                result = .failure(.transport(err.localizedDescription))
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(.transport("no HTTP response"))
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard http.statusCode == 200 else {
                result = .failure(.http(http.statusCode, body))
                return
            }
            guard let data, let judgment = AdjudicatorAPI.parse(responseData: data) else {
                result = .failure(.malformedResponse("no tool call in response"))
                return
            }
            result = .success(judgment)
        }.resume()
        sem.wait()

        return try result.get()
    }
}
