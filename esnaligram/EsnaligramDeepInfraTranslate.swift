import Foundation
import SwiftSignalKit
import Postbox
import NaturalLanguage

import Security

/// Kullanıcının kendi DeepInfra anahtarı (iOS Keychain). Yoksa derlemeye gömülü anahtar.
public enum EsnaligramCoreKeyStore {
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
        set { _ = saveKey(newValue) }
    }

    /// Update-or-add; nil/boş = sil. Başarı için errSecSuccess döner.
    @discardableResult
    public static func saveKey(_ value: String?) -> OSStatus {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            let st = SecItemDelete(base as CFDictionary)
            return st == errSecItemNotFound ? errSecSuccess : st
        }
        let attrs: [String: Any] = [kSecValueData as String: Data(v.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var st = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = base
            for (k, a) in attrs { add[k] = a }
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st
    }

    /// Anahtar + model + adres kaydı; geri okuyarak doğrular. nil = başarılı, aksi halde hata metni.
    public static func saveAll(key: String?, model: String?, baseURL: String?) -> String? {
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let u = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        UserDefaults.standard.set(m.isEmpty ? nil : m, forKey: "esn.model")
        UserDefaults.standard.set(u.isEmpty ? nil : u, forKey: "esn.baseURL")
        UserDefaults.standard.synchronize()
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            let st = saveKey(k)
            if st != errSecSuccess { return "Anahtar Keychain'e yazılamadı (OSStatus \(st))." }
            if userKey != k { return "Anahtar kaydedildi ama geri okunamadı." }
        }
        if (userModel ?? "") != m || (userBaseURL ?? "") != u { return "Model/adres kaydedilemedi." }
        return nil
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

/// Esnaligram: DeepInfra çeviri motoru (Telegram API yerine).
/// Bağlantılar/mention/hashtag korunur (placeholder → geri yazma).
public enum EsnaligramDeepInfra {
    public static let apiKey = "__DEEPINFRA_API_KEY__"
    public static let model = "deepseek-ai/DeepSeek-V4-Flash-0731"
    private static let endpoint = URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!

    /// Global otomatik çeviri (varsayılan AÇIK).
    public static var autoTranslateEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "esn.autoTranslate") == nil { return true }
            return UserDefaults.standard.bool(forKey: "esn.autoTranslate")
        }
        set { UserDefaults.standard.set(newValue, forKey: "esn.autoTranslate") }
    }

    /// Gelen mesajlar için bağlamlı (pahalı) çeviri; varsayılan KAPALI.
    public static var incomingContextEnabled: Bool { UserDefaults.standard.bool(forKey: "esn.incomingContext") }

    public static func detectLanguage(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        let conf = r.languageHypotheses(withMaximum: 1)[lang] ?? 0
        return conf >= 0.55 ? lang.rawValue : nil
    }

    struct Token {
        let placeholder: String
        let original: String
        let type: MessageTextEntityType
    }

    /// Korunan metin + token listesi. URL / TextUrl / Mention / TextMention / Hashtag / Email / Phone / BankCard / BotCommand / CustomEmoji.
    static func protect(_ text: String, entities: [MessageTextEntity]) -> (String, [Token]) {
        var tokens: [Token] = []
        var result = text
        let sorted = entities.filter { e in
            switch e.type {
            case .Url, .TextUrl, .Mention, .TextMention, .Hashtag, .Email, .PhoneNumber, .BankCard, .BotCommand, .CustomEmoji, .TonAddress:
                return true
            default: return false
            }
        }.sorted { $0.range.lowerBound > $1.range.lowerBound }
        var idx = 0
        for e in sorted {
            let start = result.index(result.startIndex, offsetBy: e.range.lowerBound, limitedBy: result.endIndex) ?? result.endIndex
            let end = result.index(result.startIndex, offsetBy: e.range.upperBound, limitedBy: result.endIndex) ?? result.endIndex
            guard start < end else { continue }
            let original = String(result[start..<end])
            let ph = "⟦E\(idx)⟧"
            tokens.insert(Token(placeholder: ph, original: original, type: e.type), at: 0)
            result.replaceSubrange(start..<end, with: ph)
            idx += 1
        }
        // Also protect bare URLs not covered by entities
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = result as NSString
            let matches = detector.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let original = ns.substring(with: m.range)
                if original.contains("⟦E") { continue }
                let ph = "⟦E\(idx)⟧"
                tokens.append(Token(placeholder: ph, original: original, type: .Url))
                result = (result as NSString).replacingCharacters(in: m.range, with: ph)
                idx += 1
            }
        }
        return (result, tokens)
    }

    static func restore(_ translated: String, tokens: [Token]) -> (String, [MessageTextEntity]) {
        var text = translated
        var entities: [MessageTextEntity] = []
        for t in tokens {
            guard let range = text.range(of: t.placeholder) else {
                // Model dropped placeholder — append original at end to not lose the link target? Better: skip entity.
                continue
            }
            let nsStart = text.distance(from: text.startIndex, to: range.lowerBound)
            text.replaceSubrange(range, with: t.original)
            let nsEnd = nsStart + t.original.count
            entities.append(MessageTextEntity(range: nsStart ..< nsEnd, type: t.type))
        }
        return (text, entities)
    }

    private static func systemPrompt(toLang: String) -> String {
        // Embedded minimal instruction; full chat prompt is for bilateral messenger use.
        // Incoming auto-translate: always into the app UI language.
        return """
        You are a translator. Translate the user's message into language code '\(toLang)'.
        Output ONLY the translation. Keep every placeholder like ⟦E0⟧ ⟦E1⟧ exactly as-is (same characters, same order).
        Do not translate or alter placeholders. Preserve meaning, tone, slang and emoji. No explanations.
        Insults, swear words, slurs and profanity must be translated with their full literal force and exact meaning:
        never soften, euphemize, censor, mask or distort them. The user wants the bare meaning of every insult.
        The input may contain RECENT CHAT MESSAGES labeled "me"/"them" marked CONTEXT ONLY. Use them only to understand
        meaning, references, gender and tone. Never translate or output them; translate only the MESSAGE TO TRANSLATE.
        Style: natural casual texting like close friends (informal address), not formal or bookish; keep jokes, flirting
        and sarcasm working with native equivalents. Never add warmth, politeness or emojis that are not in the source.
        """
    }

    /// Son ~10 mesaj, toplam ~2000 karakter.
    public static func contextString(_ lines: [String]) -> String {
        var out: [String] = []
        var total = 0
        for l in lines.suffix(20).reversed() {
            let line = String(l.prefix(600)).replacingOccurrences(of: "\n", with: " ")
            if total + line.count > 3000 { break }
            total += line.count
            out.insert(line, at: 0)
        }
        return out.joined(separator: "\n")
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (String, [MessageTextEntity])] = [:]

    /// Mesaj kimliği başına önbellekli çeviri (bağlam değişse de tekrar ücret yok).
    public static func translateMessagesSignal(items: [(String, [MessageTextEntity], String, String)], toLang: String) -> Signal<[(String, [MessageTextEntity])], NoError> {
        if items.isEmpty { return .single([]) }
        var signal: Signal<[(String, [MessageTextEntity])], NoError> = .single([])
        for item in items {
            let key = item.3 + ":" + toLang + (item.2.isEmpty ? ":c0:" : ":c1:") + String(item.0.hashValue)
            signal = signal |> mapToSignal { soFar in
                cacheLock.lock()
                let hit = cache[key]
                cacheLock.unlock()
                if let hit { return .single(soFar + [hit]) }
                return translateSignal(text: item.0, entities: item.1, toLang: toLang, context: item.2)
                |> map { result in
                    cacheLock.lock()
                    if cache.count > 3000 { cache.removeAll() }
                    cache[key] = result
                    cacheLock.unlock()
                    return soFar + [result]
                }
            }
        }
        return signal
    }

    public static func translateSignal(text: String, entities: [MessageTextEntity], toLang: String, context: String = "") -> Signal<(String, [MessageTextEntity]), NoError> {
        return Signal { subscriber in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                subscriber.putNext((text, entities))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            // Skip if already target language
            if let detected = detectLanguage(trimmed) {
                let normTo = toLang.lowercased().prefix(2)
                if detected.lowercased().hasPrefix(String(normTo)) {
                    subscriber.putNext((text, entities))
                    subscriber.putCompletion()
                    return EmptyDisposable
                }
            }
            guard let ep = EsnaligramCoreKeyStore.resolve(embeddedKey: apiKey, embeddedModel: model) else {
                subscriber.putNext((text, entities))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let (protected, tokens) = protect(text, entities: entities)
            let userContent: String = context.isEmpty ? protected : "RECENT CHAT MESSAGES (CONTEXT ONLY - DO NOT TRANSLATE, DO NOT OUTPUT):\n" + context + "\n\nMESSAGE TO TRANSLATE (output only its translation):\n" + protected
            let req = EsnaligramCoreKeyStore.makeRequest(ep, system: systemPrompt(toLang: toLang), user: userContent, temperature: 0.2, maxTokens: 2048, timeout: 45)
            let task = URLSession.shared.dataTask(with: req) { data, _, error in
                if error != nil || data == nil {
                    subscriber.putNext((text, entities))
                    subscriber.putCompletion()
                    return
                }
                var out = text
                var outEnt = entities
                if let content = EsnaligramCoreKeyStore.parse(data), !content.isEmpty {
                    let restored = restore(content, tokens: tokens)
                    out = restored.0
                    outEnt = restored.1
                }
                subscriber.putNext((out, outEnt))
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable { task.cancel() }
        }
    }

    public static func translateTextsSignal(texts: [(String, [MessageTextEntity])], toLang: String) -> Signal<[(String, [MessageTextEntity])], NoError> {
        if texts.isEmpty { return .single([]) }
        var signal: Signal<[(String, [MessageTextEntity])], NoError> = .single([])
        for item in texts {
            signal = signal |> mapToSignal { soFar in
                return translateSignal(text: item.0, entities: item.1, toLang: toLang)
                |> map { soFar + [$0] }
            }
        }
        return signal
    }
}
