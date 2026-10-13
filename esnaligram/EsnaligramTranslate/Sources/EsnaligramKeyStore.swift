import Foundation
import Security

/// Kullanıcının kendi DeepInfra anahtarı (iOS Keychain). Yoksa derlemeye gömülü anahtar.
public enum EsnaligramKeyStore {
    static let service = "esnaligram.deepinfra"
    static let account = "apiKey"
    public static var userKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
            return s
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
    public static func effectiveKey(embedded: String) -> String? {
        if let k = userKey { return k }
        let e = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
        return (e.isEmpty || e.hasPrefix("__")) ? nil : e
    }

    public static var userModel: String? {
        get { let v = UserDefaults.standard.string(forKey: "esn.model")?.trimmingCharacters(in: .whitespacesAndNewlines); return (v?.isEmpty ?? true) ? nil : v }
        set { UserDefaults.standard.set(newValue, forKey: "esn.model") }
    }
    public static var userBaseURL: String? {
        get { let v = UserDefaults.standard.string(forKey: "esn.baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines); return (v?.isEmpty ?? true) ? nil : v }
        set { UserDefaults.standard.set(newValue, forKey: "esn.baseURL") }
    }

    public struct Endpoint {
        public let name: String
        public let baseURL: String
        public let key: String
        public let model: String
        public let anthropic: Bool
    }

    /// Anahtar önekinden / model adından sağlayıcı tespiti. Özel adres her şeyi geçersiz kılar.
    public static func detect(key: String, model: String?, baseURL: String?) -> (name: String, baseURL: String, defaultModel: String, anthropic: Bool) {
        let m = (model ?? "").lowercased()
        var r: (String, String, String, Bool)
        if key.hasPrefix("sk-di-") { r = ("DeepInfra", "https://api.deepinfra.com/v1/openai", "deepseek-ai/DeepSeek-V4-Flash-0731", false) }
        else if key.hasPrefix("xai-") { r = ("xAI", "https://api.x.ai/v1", "grok-3-mini", false) }
        else if key.hasPrefix("gsk_") { r = ("Groq", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile", false) }
        else if key.hasPrefix("AIza") { r = ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash", false) }
        else if key.hasPrefix("sk-or-") { r = ("OpenRouter", "https://openrouter.ai/api/v1", "deepseek/deepseek-chat", false) }
        else if key.hasPrefix("sk-ant-") { r = ("Anthropic", "https://api.anthropic.com/v1", "claude-haiku-4-5", true) }
        else if key.hasPrefix("sk-") && m.contains("deepseek") { r = ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat", false) }
        else if key.hasPrefix("sk-") && (m.contains("moonshot") || m.contains("kimi")) { r = ("Moonshot", "https://api.moonshot.ai/v1", "kimi-k2-0905-preview", false) }
        else if key.hasPrefix("sk-") && m.contains("mistral") { r = ("Mistral", "https://api.mistral.ai/v1", "mistral-small-latest", false) }
        else if key.hasPrefix("sk-") { r = ("OpenAI", "https://api.openai.com/v1", "gpt-4.1-mini", false) }
        else if m.contains("claude") { r = ("Anthropic", "https://api.anthropic.com/v1", "claude-haiku-4-5", true) }
        else if m.hasPrefix("gemini") { r = ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash", false) }
        else if m.hasPrefix("grok") { r = ("xAI", "https://api.x.ai/v1", "grok-3-mini", false) }
        else { r = ("DeepInfra", "https://api.deepinfra.com/v1/openai", "deepseek-ai/DeepSeek-V4-Flash-0731", false) }
        if let b = baseURL, !b.isEmpty {
            var u = b; while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix("/chat/completions") { u = String(u.dropLast("/chat/completions".count)) }
            let anth = u.contains("anthropic.com")
            r = ("Özel (" + (URL(string: u)?.host ?? u) + ")", u, r.2, anth)
        }
        return r
    }

    public static func resolve(embeddedKey: String, embeddedModel: String) -> Endpoint? {
        let usingUser = userKey != nil
        guard let key = effectiveKey(embedded: embeddedKey) else { return nil }
        let d = detect(key: key, model: userModel, baseURL: userBaseURL)
        let model = userModel ?? (usingUser ? d.defaultModel : embeddedModel)
        return Endpoint(name: d.name, baseURL: d.baseURL, key: key, model: model, anthropic: d.anthropic)
    }

    public static func makeRequest(_ ep: Endpoint, system: String, user: String, temperature: Double, maxTokens: Int, timeout: TimeInterval) -> URLRequest {
        var req: URLRequest
        var body: [String: Any]
        if ep.anthropic {
            req = URLRequest(url: URL(string: ep.baseURL + "/messages")!)
            req.setValue(ep.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": ep.model, "max_tokens": maxTokens, "temperature": temperature,
                    "messages": [["role": "user", "content": user]]]
            if !system.isEmpty { body["system"] = system }
        } else {
            req = URLRequest(url: URL(string: ep.baseURL + "/chat/completions")!)
            req.setValue("Bearer \(ep.key)", forHTTPHeaderField: "Authorization")
            var msgs: [[String: String]] = []
            if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
            msgs.append(["role": "user", "content": user])
            body = ["model": ep.model, "max_tokens": maxTokens, "temperature": temperature, "messages": msgs]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// OpenAI veya Anthropic yanıtından metni çıkarır.
    public static func parse(_ data: Data?) -> String? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any], let c = msg["content"] as? String {
            return c.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let blocks = json["content"] as? [[String: Any]] {
            let t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
