import Foundation
import SwiftSignalKit
import Postbox
import NaturalLanguage

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
        """
    }

    public static func translateSignal(text: String, entities: [MessageTextEntity], toLang: String) -> Signal<(String, [MessageTextEntity]), NoError> {
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
            let (protected, tokens) = protect(text, entities: entities)
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 45
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "max_tokens": 2048,
                "messages": [
                    ["role": "system", "content": systemPrompt(toLang: toLang)],
                    ["role": "user", "content": protected]
                ]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let task = URLSession.shared.dataTask(with: req) { data, _, error in
                if error != nil || data == nil {
                    subscriber.putNext((text, entities))
                    subscriber.putCompletion()
                    return
                }
                var out = text
                var outEnt = entities
                if let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                   let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                   let content = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
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
