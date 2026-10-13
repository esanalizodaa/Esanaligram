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


    /// Noktalama temizleme: korunan parçalar (URL, @mention, #etiket, e-posta, rakamlı kodlar, ⟦E0⟧, emoji) hariç.
    /// Küçük harf, tek boşluk; soru ise sonda tek "?".
    public static func sanitizePunctuation(_ text: String) -> String {
        let trimmedAll = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isQuestion = trimmedAll.hasSuffix("?") || trimmedAll.hasSuffix("？") || trimmedAll.hasSuffix("؟")
        func isProtected(_ w: String) -> Bool {
            if w.contains("⟦") || w.contains("://") || w.hasPrefix("www.") || w.hasPrefix("@") || w.hasPrefix("#") || w.hasPrefix("/") { return true }
            if w.contains("@") && w.contains(".") { return true }
            if w.rangeOfCharacter(from: .decimalDigits) != nil && w.rangeOfCharacter(from: .letters) != nil { return true }
            return false
        }
        func keepScalar(_ u: Unicode.Scalar) -> Bool {
            if u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value >= 0x2100) { return true }
            if u.value == 0x200D || (0xFE00...0xFE0F).contains(u.value) || (0x1F3FB...0x1F3FF).contains(u.value) { return true }
            if CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u) { return false }
            return true
        }
        var lines: [String] = []
        for line in trimmedAll.components(separatedBy: .newlines) {
            var words: [String] = []
            for raw in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                var w = String(raw)
                if isProtected(w) {
                    // yalnız sondaki cümle noktalamasını at
                    while let last = w.unicodeScalars.last, ".,;:!?…»)\"'".unicodeScalars.contains(last), !w.hasSuffix("⟧") { w.unicodeScalars.removeLast() }
                } else if w.rangeOfCharacter(from: .decimalDigits) != nil {
                    // sayı: 1.5 / 10:30 / 1,000 içindeki ayraçları koru, uçları temizle
                    w = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "%")))
                } else {
                    var out = String.UnicodeScalarView()
                    for u in w.unicodeScalars where keepScalar(u) { out.append(u) }
                    w = String(out).lowercased()
                }
                if !w.isEmpty { words.append(w) }
            }
            if !words.isEmpty { lines.append(words.joined(separator: " ")) }
        }
        var result = lines.joined(separator: "\n")
        if isQuestion && !result.isEmpty && !result.hasSuffix("?") { result += "?" }
        return result
    }

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
        for l in lines.suffix(10).reversed() {
            let line = String(l.prefix(600)).replacingOccurrences(of: "\n", with: " ")
            if total + line.count > 3000 { break }
            total += line.count
            out.insert(line, at: 0)
        }
        return out.joined(separator: "\n")
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (String, [MessageTextEntity])] = [:]

    /// Sinyalleri 6'lı gruplar halinde paralel çalıştırır (sıra korunur).
    static func runConcurrently(_ signals: [Signal<(String, [MessageTextEntity]), NoError>]) -> Signal<[(String, [MessageTextEntity])], NoError> {
        if signals.isEmpty { return .single([]) }
        var result: Signal<[(String, [MessageTextEntity])], NoError> = .single([])
        var i = 0
        while i < signals.count {
            let chunk = Array(signals[i ..< min(i + 6, signals.count)])
            i += 6
            result = result |> mapToSignal { soFar -> Signal<[(String, [MessageTextEntity])], NoError> in
                return combineLatest(chunk) |> take(1) |> map { soFar + $0 }
            }
        }
        return result
    }

    /// Mesaj kimliği başına önbellekli çeviri; istekler paralel.
    public static func translateMessagesSignal(items: [(String, [MessageTextEntity], String, String)], toLang: String) -> Signal<[(String, [MessageTextEntity])], NoError> {
        if items.isEmpty { return .single([]) }
        var signals: [Signal<(String, [MessageTextEntity]), NoError>] = []
        for item in items {
            let key = item.3 + ":" + toLang + (item.2.isEmpty ? ":c0:" : ":c1:") + String(item.0.hashValue)
            cacheLock.lock()
            let hit = cache[key]
            cacheLock.unlock()
            if let hit {
                signals.append(.single(hit))
                continue
            }
            signals.append(translateSignal(text: item.0, entities: item.1, toLang: toLang, context: item.2)
            |> map { result -> (String, [MessageTextEntity]) in
                cacheLock.lock()
                if cache.count > 3000 { cache.removeAll() }
                cache[key] = result
                cacheLock.unlock()
                return result
            })
        }
        return runConcurrently(signals)
    }

    /// Google'ın bozduğu yer tutucuları (⟦ E0 ⟧ gibi) düzeltir.
    static func normalizePlaceholders(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "⟦\\s*[EeЕе]\\s*(\\d+)\\s*⟧") else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "⟦E$1⟧")
    }

    /// Anahtarsız ücretsiz Google Translate. Hata / 429 durumunda nil.
    static func googleRequest(_ text: String, toLang: String, completion: @escaping (String?, String?) -> Void) -> URLSessionDataTask? {
        var tl = toLang.lowercased()
        if tl.hasSuffix("-raw") { tl = String(tl.dropLast(4)) }
        if tl.hasPrefix("zh") {
            tl = (tl.contains("hant") || tl.contains("tw") || tl.contains("hk")) ? "zh-TW" : "zh-CN"
        } else if let dash = tl.firstIndex(of: "-") {
            tl = String(tl[..<dash])
        }
        if tl == "he" { tl = "iw" }
        if tl.isEmpty { tl = "en" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed) else { completion(nil, nil); return nil }
        let base = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(tl)&dt=t"
        var req: URLRequest
        if q.count <= 6000, let url = URL(string: base + "&q=" + q) {
            req = URLRequest(url: url)
            req.httpMethod = "GET"
        } else if let url = URL(string: base) {
            req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(("q=" + q).utf8)
        } else {
            completion(nil, nil); return nil
        }
        req.timeoutInterval = 4
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            guard error == nil, let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = json.first as? [Any] else {
                completion(nil, nil); return
            }
            var out = ""
            for seg in segments {
                if let arr = seg as? [Any], let str = arr.first as? String { out += str }
            }
            let src: String? = json.count > 2 ? (json[2] as? String) : nil
            completion(out.isEmpty ? nil : out, src)
        }
        task.resume()
        return task
    }

    /// Yapay zekâ çevirisi. Başarısızsa nil.
    static func aiSignal(text: String, entities: [MessageTextEntity], toLang: String, context: String) -> Signal<(String, [MessageTextEntity])?, NoError> {
        return Signal { subscriber in
            guard let ep = EsnaligramCoreKeyStore.resolve(embeddedKey: apiKey, embeddedModel: model) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let (protected, tokens) = protect(text, entities: entities)
            let userContent: String = context.isEmpty ? protected : "RECENT CHAT MESSAGES (CONTEXT ONLY - DO NOT TRANSLATE, DO NOT OUTPUT):\n" + context + "\n\nMESSAGE TO TRANSLATE (output only its translation):\n" + protected
            let req = EsnaligramCoreKeyStore.makeRequest(ep, system: systemPrompt(toLang: toLang), user: userContent, temperature: 0.2, maxTokens: 2048, timeout: 20)
            let task = URLSession.shared.dataTask(with: req) { data, _, error in
                if error == nil, let content = EsnaligramCoreKeyStore.parse(data), !content.isEmpty {
                    let restored = restore(sanitizePunctuation(normalizePlaceholders(content)), tokens: tokens)
                    subscriber.putNext((restored.0, restored.1))
                } else {
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable { task.cancel() }
        }
    }

    /// Ücretsiz Google çevirisi (bağlantılar korunur). Başarısızsa nil.
    static func googleSignal(text: String, entities: [MessageTextEntity], toLang: String) -> Signal<(String, [MessageTextEntity])?, NoError> {
        return Signal { subscriber in
            let (protected, tokens) = protect(text, entities: entities)
            let task = googleRequest(protected, toLang: toLang) { translated, _ in
                guard let translated else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                let fixed = normalizePlaceholders(translated)
                if tokens.contains(where: { !fixed.contains($0.placeholder) }) {
                    // Bağlantı kayboldu: düz metni ayrı çevir (hızlı), bağlantısız göster
                    let _ = googleRequest(text, toLang: toLang) { plain, _ in
                        if let plain, !plain.isEmpty {
                            subscriber.putNext((sanitizePunctuation(plain), []))
                        } else {
                            subscriber.putNext(nil)
                        }
                        subscriber.putCompletion()
                    }
                    return
                }
                let restored = restore(sanitizePunctuation(fixed), tokens: tokens)
                subscriber.putNext(restored.0.isEmpty ? nil : (restored.0, restored.1))
                subscriber.putCompletion()
            }
            return ActionDisposable { task?.cancel() }
        }
    }

    public static func translateSignal(text: String, entities: [MessageTextEntity], toLang: String, context: String = "", forceAI: Bool = false) -> Signal<(String, [MessageTextEntity]), NoError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .single((text, entities))
        }
        if !forceAI, let detected = detectLanguage(trimmed) {
            let normTo = String(toLang.lowercased().prefix(2))
            if detected.lowercased().hasPrefix(normTo) {
                return .single((text, entities))
            }
        }
        let original: (String, [MessageTextEntity]) = (text, entities)
        if forceAI || !context.isEmpty {
            return aiSignal(text: text, entities: entities, toLang: toLang, context: context)
            |> map { $0 ?? original }
        }
        return googleSignal(text: text, entities: entities, toLang: toLang)
        |> mapToSignal { result -> Signal<(String, [MessageTextEntity]), NoError> in
            if let result {
                return .single(result)
            }
            return aiSignal(text: text, entities: entities, toLang: toLang, context: "")
            |> map { $0 ?? original }
        }
    }

    public static func translateTextsSignal(texts: [(String, [MessageTextEntity])], toLang: String) -> Signal<[(String, [MessageTextEntity])], NoError> {
        return runConcurrently(texts.map { translateSignal(text: $0.0, entities: $0.1, toLang: toLang) })
    }
}

/// Esnaligram: tek mesajı yapay zekâ ile (son en fazla 10 mesaj bağlamıyla) çevirir ve
/// mesajın çevirisi olarak kaydeder. Başarısızsa nil.
public func esnaligramAITranslateMessage(postbox: Postbox, messageId: MessageId, toLang: String) -> Signal<String?, NoError> {
    return postbox.transaction { transaction -> (String, [MessageTextEntity], String)? in
        guard let message = transaction.getMessage(messageId), !message.text.isEmpty else {
            return nil
        }
        let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        var lines: [String] = []
        var scanned = 0
        transaction.scanTopMessages(peerId: messageId.peerId, namespace: messageId.namespace, limit: 300, { m in
            scanned += 1
            if m.id.id < messageId.id && !m.text.isEmpty {
                lines.append((m.flags.contains(.Incoming) ? "them: " : "me: ") + m.text)
            }
            return lines.count < 10 && scanned < 300
        })
        return (message.text, entities, EsnaligramDeepInfra.contextString(Array(lines.reversed())))
    }
    |> mapToSignal { data -> Signal<String?, NoError> in
        guard let data else {
            return .single(nil)
        }
        return EsnaligramDeepInfra.aiSignal(text: data.0, entities: data.1, toLang: toLang, context: data.2)
        |> mapToSignal { result -> Signal<String?, NoError> in
            guard let result else {
                return .single(nil)
            }
            return postbox.transaction { transaction -> String? in
                let updatedAttribute = TranslationMessageAttribute(text: result.0, entities: result.1, toLang: toLang)
                transaction.updateMessage(messageId, update: { currentMessage in
                    let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
                    var attributes = currentMessage.attributes.filter { !($0 is TranslationMessageAttribute) }
                    attributes.append(updatedAttribute)
                    return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
                })
                return result.0
            }
        }
    }
}
