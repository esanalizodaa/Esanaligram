import Foundation

/// Esnaligram: anahtarsız ücretsiz Google Translate (translate.googleapis.com, client=gtx).
public enum EsnaligramGoogleTranslate {
    public static func normalizeLang(_ lang: String) -> String {
        var c = lang.lowercased()
        if c.hasSuffix("-raw") { c = String(c.dropLast(4)) }
        if c.hasPrefix("zh") {
            return (c.contains("hant") || c.contains("tw") || c.contains("hk")) ? "zh-TW" : "zh-CN"
        }
        if c.hasPrefix("mni") { return "mni-Mtei" }
        if let dash = c.firstIndex(of: "-") { c = String(c[..<dash]) }
        switch c {
        case "he": return "iw"
        case "jv": return "jw"
        case "nb", "nn": return "no"
        case "fil": return "tl"
        case "yue": return "zh-TW"
        default: break
        }
        return c.isEmpty ? "en" : c
    }

    /// Sonuç: (çeviri, algılanan kaynak dil) veya hata/limit durumunda nil.
    @discardableResult
    public static func translate(_ text: String, toLang: String, completion: @escaping (String?, String?) -> Void) -> URLSessionDataTask? {
        let tl = normalizeLang(toLang)
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
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            guard error == nil, let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = json.first as? [Any] else {
                completion(nil, nil); return
            }
            var out = ""
            for seg in segments {
                if let arr = seg as? [Any], let s = arr.first as? String { out += s }
            }
            let src = json.count > 2 ? json[2] as? String : nil
            completion(out.isEmpty ? nil : out, src)
        }
        task.resume()
        return task
    }
}
