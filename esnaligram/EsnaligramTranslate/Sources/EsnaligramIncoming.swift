import Foundation
import NaturalLanguage

/// Gelen mesajların otomatik çevirisi (varsayılan AÇIK). Bağlantı/mention/hashtag/text_link
/// entity'leri yer tutucularla korunur ve çeviriden sonra doğru offset'lerle geri yerleştirilir.
public enum EsnaligramIncoming {
    private static let key = "esn.autoTranslateIncoming"
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Bir entity: UTF-16 aralığı + verbatim (link/mention gibi aynen korunacak) mi, yoksa
    /// içi çevrilecek bir sarmalayıcı (text_link, kalın vb.) mı.
    public struct Span {
        public let range: NSRange
        public let verbatim: Bool
        public let tag: Int
        public init(range: NSRange, verbatim: Bool, tag: Int) { self.range = range; self.verbatim = verbatim; self.tag = tag }
    }

    private static var cache: [String: (String, [Int: NSRange])] = [:]
    private static let cacheLock = NSLock()

    /// Metin zaten hedef dildeyse true (çeviri atlanır).
    public static func isAlready(_ text: String, in lang: String) -> Bool {
        let r = NLLanguageRecognizer(); r.processString(text)
        guard let d = r.dominantLanguage?.rawValue else { return false }
        return d.hasPrefix(lang) || lang.hasPrefix(d)
    }

    /// Çakışmayan span'leri yer tutucularla değiştirir.
    static func protect(_ text: String, _ spans: [Span]) -> (String, [Int: String]) {
        let ns = text as NSString
        var out = ""
        var verbatimValues: [Int: String] = [:]
        var cursor = 0
        var
