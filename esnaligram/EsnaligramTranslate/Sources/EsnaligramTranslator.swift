import Foundation
import UIKit
import NaturalLanguage
import Security

public final class EsnaligramTranslator {
    public static let shared = EsnaligramTranslator()
    private let defaults = UserDefaults.standard

    /// Elle seçilen hedef dil (ISO kodu). nil = otomatik algıla.
    public var manualTargetLanguage: String? {
        get { defaults.string(forKey: "esn.targetLang") }
        set { defaults.set(newValue, forKey: "esn.targetLang") }
    }
    /// Uzun basınca açılan ek prompt alanı; sistem prompt'una eklenir.
    public var extraPrompt: String {
        get { defaults.string(forKey: "esn.extraPrompt") ?? "" }
        set { defaults.set(newValue, forKey: "esn.extraPrompt") }
    }

    public enum TranslateError: Error { case targetUnknown, network(String), empty, noKey }

    public static let languages: [(code: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("uz", "Oʻzbek"), ("kk", "Қазақ"), ("uk", "Українська"),
        ("az", "Azərbaycan"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("ar", "العربية"), ("fa", "فارسی"), ("ky", "Кыргыз"), ("tg", "Тоҷикӣ"), ("pl", "Polski"),
        ("pt", "Português"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"), ("tr", "Türkçe")
    ]

    /// Son ~10 satır, toplam ~2000 karakter.
    public static func trimContext(_ lines: [String]) -> String {
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

    /// Küçük test isteği.
    public static func testEndpoint(_ ep: EsnaligramKeyStore.Endpoint, completion: @escaping (String) -> Void) {
        let req = EsnaligramKeyStore.makeRequest(ep, system: "", user: "hi", temperature: 0, maxTokens: 1, timeout: 20)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let msg: String
            if let err { msg = "Hata: " + err.localizedDescription }
            else if let code = (resp as? HTTPURLResponse)?.statusCode {
                if code == 200 { msg = "OK ✅ (\(ep.name), \(ep.model))" }
                else { msg = "Hata: HTTP \(code) " + String((String(data: data ?? Data(), encoding: .utf8) ?? "").prefix(160)) }
            } else { msg = "Hata" }
            DispatchQueue.main.async { completion(msg) }
        }.resume()
    }


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

    public static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        let conf = r.languageHypotheses(withMaximum: 1)[lang] ?? 0
        return conf >= 0.5 ? lang.rawValue : nil
    }

    /// Karşı tarafın son mesajlarından hedef dili bulur. Manuel seçim varsa o kullanılır.
    public func resolveTarget(peerTexts: [String]) -> String? {
        if let m = manualTargetLanguage { return m }
        let joined = peerTexts.suffix(15).joined(separator: "\n")
        guard !joined.isEmpty, let l = Self.detect(joined), l != "tr" else { return nil }
        return l
    }

    /// contextLines: "me: ..." / "them: ..." formatında son mesajlar (eski → yeni).
    public func translate(_ text: String, peerTexts: [String], contextLines: [String] = [], withContext: Bool = false, completion: @escaping (Result<String, TranslateError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(.empty)); return }
        guard let ep = EsnaligramKeyStore.resolve(embeddedKey: EsnaligramSecrets.deepInfraKey, embeddedModel: EsnaligramSecrets.model) else { completion(.failure(.noKey)); return }
        let isTurkish = Self.detect(trimmed) == "tr"
        var context: String
        if isTurkish {
            guard let target = resolveTarget(peerTexts: peerTexts) else { completion(.failure(.targetUnknown)); return }
            context = "CONTEXT: The other person's language is '\(target)'. Translate the user's message into this language."
        } else {
            context = "CONTEXT: Translate this message into natural Turkish."
        }
        let ctx = withContext ? Self.trimContext(contextLines) : ""
        var userContent = trimmed
        if !ctx.isEmpty {
            userContent = "RECENT CHAT MESSAGES (CONTEXT ONLY - DO NOT TRANSLATE, DO NOT OUTPUT):\n" + ctx + "\n\nMESSAGE TO TRANSLATE (output only its translation):\n" + trimmed
        }
        var sys = withContext ? EsnaligramPrompt.system : EsnaligramPrompt.compact
        let extra = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { sys += "\n\nADDITIONAL USER INSTRUCTIONS:\n" + extra }
        sys += "\n\n" + context

        let req = EsnaligramKeyStore.makeRequest(ep, system: sys, user: userContent, temperature: 0.3, maxTokens: 1024, timeout: 40)
        URLSession.shared.dataTask(with: req) { data, _, error in
            let result: Result<String, TranslateError>
            if let error = error {
                result = .failure(.network(error.localizedDescription))
            } else if let raw = EsnaligramKeyStore.parse(data) {
                let out = Self.sanitizePunctuation(raw)
                result = out.isEmpty ? .failure(.empty) : .success(out)
            } else {
                result = .failure(.network(String(data: data ?? Data(), encoding: .utf8) ?? "geçersiz yanıt"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

/// Çıkartma (sticker) butonunun soluna eklenen çeviri butonu.
/// Dokun = çevir (tekrar dokun = geri al), uzun bas = dil seç + ek prompt.
public final class EsnaligramTranslateButton: UIButton {
    public var getText: (() -> String)?
    public var setText: ((String) -> Void)?
    /// "me: ..." / "them: ..." satırları (eski → yeni)
    public var getPeerTexts: ((@escaping ([String]) -> Void) -> Void)?
    public var presentController: ((UIViewController) -> Void)?

    private var undoText: String?
    private var lastTranslated: String?
    private let spinner = UIActivityIndicatorView(style: .medium)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        setImage(UIImage(systemName: "character.bubble", withConfiguration: cfg), for: .normal)
        accessibilityLabel = "Çevir (çift dokun: bağlamla tekrar çevir)"
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        dbl.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.require(toFail: dbl)
        addGestureRecognizer(dbl)
        addGestureRecognizer(single)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        spinner.hidesWhenStopped = true
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func layoutSubviews() { super.layoutSubviews(); spinner.center = CGPoint(x: bounds.midX, y: bounds.midY) }

    public func updateColor(_ color: UIColor) { tintColor = color; spinner.color = color }

    /// Çift dokunuş: tam prompt + son sohbet mesajlarıyla (bağlamla) tekrar çevir.
    @objc private func doubleTapped() {
        var current = getText?() ?? ""
        if let undo = undoText, current == lastTranslated { current = undo; undoText = nil; lastTranslated = nil }
        run(current, withContext: true)
    }

    @objc private func tapped() {
        let current = getText?() ?? ""
        if let undo = undoText, current == lastTranslated {
            setText?(undo); undoText = nil; lastTranslated = nil; return
        }
        run(current, withContext: false)
    }

    private func run(_ current: String, withContext: Bool) {
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !spinner.isAnimating else { return }
        setLoading(true)
        let go: ([String]) -> Void = { [weak self] lines in
            let peerTexts = lines.filter { $0.hasPrefix("them: ") }.map { String($0.dropFirst(6)) }
            EsnaligramTranslator.shared.translate(current, peerTexts: peerTexts, contextLines: lines, withContext: withContext) { result in
                guard let self else { return }
                self.setLoading(false)
                switch result {
                case let .success(out):
                    self.undoText = current; self.lastTranslated = out; self.setText?(out)
                case .failure(.targetUnknown):
                    self.showLanguagePicker(message: "Karşı tarafın dili algılanamadı. Dili seç, sonra tekrar Çevir'e bas.")
                case .failure(.empty):
                    break
                case .failure(.noKey):
                    self.showLanguagePicker(message: "DeepInfra API anahtarı yok. Aşağıya anahtarını gir ve Kaydet'e bas.")
                case let .failure(.network(e)):
                    self.alert("Çeviri hatası", e)
                }
            }
        }
        if let getPeerTexts { getPeerTexts { texts in DispatchQueue.main.async { go(texts) } } } else { go([]) }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { showLanguagePicker(message: nil) }
    }

    private func setLoading(_ v: Bool) {
        if v { spinner.startAnimating(); imageView?.alpha = 0 } else { spinner.stopAnimating(); imageView?.alpha = 1 }
    }

    private func alert(_ title: String, _ msg: String) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Tamam", style: .default))
        presentController?(a)
    }

    public func showLanguagePicker(message: String?) {
        let sheet = EsnaligramTranslateSettingsController(message: message)
        let nav = UINavigationController(rootViewController: sheet)
        if let s = nav.sheetPresentationController { s.detents = [.medium(), .large()] }
        presentController?(nav)
    }
}

/// Uzun basınca açılan ekran: hedef dil listesi + ek prompt alanı.
public final class EsnaligramTranslateSettingsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let promptView = UITextView()
    private let message: String?
    private let keyField = UITextField()
    private let modelField = UITextField()
    private let urlField = UITextField()
    private var keyStatus: String?

    public init(message: String?) { self.message = message; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Çeviri dili"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        table.dataSource = self; table.delegate = self
        table.frame = view.bounds; table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        promptView.text = EsnaligramTranslator.shared.extraPrompt
        promptView.font = .systemFont(ofSize: 15)
        promptView.backgroundColor = .secondarySystemGroupedBackground
        promptView.layer.cornerRadius = 10
        keyField.placeholder = "DeepInfra API anahtarı (sk-di-…)"
        keyField.isSecureTextEntry = true
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.clearButtonMode = .whileEditing
        keyField.text = EsnaligramKeyStore.userKey
        keyField.addTarget(self, action: #selector(fieldsChanged), for: .editingChanged)
        modelField.placeholder = "Model (boş = otomatik)"
        modelField.text = EsnaligramKeyStore.userModel
        urlField.placeholder = "API adresi (gelişmiş, boş = otomatik)"
        urlField.text = EsnaligramKeyStore.userBaseURL
        urlField.keyboardType = .URL
        for f in [modelField, urlField] {
            f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
            f.addTarget(self, action: #selector(fieldsChanged), for: .editingChanged)
        }
        view.addSubview(table)
    }
    @objc private func done() {
        EsnaligramTranslator.shared.extraPrompt = promptView.text ?? ""
        dismiss(animated: true)
    }
    public func numberOfSections(in t: UITableView) -> Int { 4 }
    public func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        if s == 0 { return 4 } // key, model, base URL, buttons
        if s == 1 { return 2 } // auto-translate toggle + context toggle
        if s == 2 { return 1 } // prompt
        return EsnaligramTranslator.languages.count + 1
    }
    public func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        if s == 0 { return "API anahtarı" }
        if s == 1 { return "Gelen mesajlar" }
        if s == 2 { return "Ek prompt (isteğe bağlı)" }
        return "Giden çeviri — hedef dil"
    }
    public func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        if s == 0 {
            var f: String = EsnaligramKeyStore.userKey != nil ? "Kendi anahtarın kullanılıyor (Keychain)." :
                (EsnaligramKeyStore.effectiveKey(embedded: EsnaligramSecrets.deepInfraKey) != nil ? "Uygulamaya gömülü anahtar kullanılıyor." : "Anahtar yok.")
            f += "\nSağlayıcı: " + detectedLabel()
            if let r = keyStatus { f += "\n" + r }
            if let message { f = message + "\n" + f }
            return f
        }
        if s == 1 { return "Açıkken gelen mesajlar uygulama diline çevrilir. Orijinal için çeviriye dokun. Bağlamla çeviri tam prompt ve son sohbet mesajlarını gönderir, daha doğru ama daha pahalı. Giden mesajda çeviri tuşuna çift dokunarak bağlamla çevirebilirsin." }
        return nil
    }
    public func tableView(_ t: UITableView, heightForRowAt ip: IndexPath) -> CGFloat { ip.section == 2 ? 120 : 44 }
    public func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: nil)
        if ip.section == 0 {
            c.selectionStyle = .none
            if ip.row == 1 || ip.row == 2 {
                let f = ip.row == 1 ? modelField : urlField
                f.frame = c.contentView.bounds.insetBy(dx: 16, dy: 4)
                f.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                c.contentView.addSubview(f)
                return c
            }
            if ip.row == 0 {
                keyField.frame = c.contentView.bounds.insetBy(dx: 16, dy: 4)
                keyField.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                c.contentView.addSubview(keyField)
                let eye = UIButton(type: .system)
                eye.setImage(UIImage(systemName: keyField.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
                eye.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
                eye.addTarget(self, action: #selector(toggleShow(_:)), for: .touchUpInside)
                c.accessoryView = eye
            } else {
                let stack = UIStackView()
                stack.axis = .horizontal; stack.distribution = .fillEqually
                for (title, sel) in [("Kaydet", #selector(saveKey)), ("Sil", #selector(clearKey)), ("Test", #selector(testKey))] {
                    let b = UIButton(type: .system); b.setTitle(title, for: .normal)
                    if title == "Sil" { b.tintColor = .systemRed }
                    b.addTarget(self, action: sel, for: .touchUpInside)
                    stack.addArrangedSubview(b)
                }
                stack.frame = c.contentView.bounds; stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                c.contentView.addSubview(stack)
            }
            return c
        }
        if ip.section == 1 && ip.row == 1 {
            c.textLabel?.text = "Gelen: bağlamla çevir"
            let sw = UISwitch()
            sw.isOn = UserDefaults.standard.bool(forKey: "esn.incomingContext")
            sw.addTarget(self, action: #selector(ctxChanged(_:)), for: .valueChanged)
            c.accessoryView = sw; c.selectionStyle = .none
            return c
        }
        if ip.section == 1 {
            c.textLabel?.text = "Otomatik çevir (gelen)"
            let sw = UISwitch()
            if UserDefaults.standard.object(forKey: "esn.autoTranslate") == nil { sw.isOn = true }
            else { sw.isOn = UserDefaults.standard.bool(forKey: "esn.autoTranslate") }
            sw.addTarget(self, action: #selector(autoChanged(_:)), for: .valueChanged)
            c.accessoryView = sw; c.selectionStyle = .none
            return c
        }
        if ip.section == 2 {
            promptView.frame = c.contentView.bounds.insetBy(dx: 12, dy: 6)
            promptView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            c.contentView.addSubview(promptView); c.selectionStyle = .none
            return c
        }
        let code: String? = ip.row == 0 ? nil : EsnaligramTranslator.languages[ip.row - 1].code
        c.textLabel?.text = ip.row == 0 ? "Otomatik algıla" : EsnaligramTranslator.languages[ip.row - 1].name
        c.accessoryType = EsnaligramTranslator.shared.manualTargetLanguage == code ? .checkmark : .none
        return c
    }
    @objc private func ctxChanged(_ sw: UISwitch) {
        UserDefaults.standard.set(sw.isOn, forKey: "esn.incomingContext")
    }
    @objc private func autoChanged(_ sw: UISwitch) {
        UserDefaults.standard.set(sw.isOn, forKey: "esn.autoTranslate")
    }
    @objc private func toggleShow(_ b: UIButton) {
        keyField.isSecureTextEntry.toggle()
        b.setImage(UIImage(systemName: keyField.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
    }
    private func detectedLabel() -> String {
        let typed = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (EsnaligramKeyStore.effectiveKey(embedded: EsnaligramSecrets.deepInfraKey) ?? "") : typed
        let model = (modelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = EsnaligramKeyStore.detect(key: key, model: model.isEmpty ? nil : model, baseURL: urlField.text)
        return d.name + " — " + (model.isEmpty ? d.defaultModel : model)
    }
    private func typedEndpoint() -> EsnaligramKeyStore.Endpoint? {
        let typed = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? EsnaligramKeyStore.effectiveKey(embedded: EsnaligramSecrets.deepInfraKey) : typed else { return nil }
        let model = (modelField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = EsnaligramKeyStore.detect(key: key, model: model.isEmpty ? nil : model, baseURL: urlField.text)
        let usingEmbedded = typed.isEmpty && EsnaligramKeyStore.userKey == nil
        let m = model.isEmpty ? (usingEmbedded ? EsnaligramSecrets.model : d.defaultModel) : model
        return EsnaligramKeyStore.Endpoint(name: d.name, baseURL: d.baseURL, key: key, model: m, anthropic: d.anthropic)
    }
    @objc private func fieldsChanged() {
        if let footer = table.footerView(forSection: 0) {
            footer.textLabel?.text = self.tableView(table, titleForFooterInSection: 0)
            footer.sizeToFit()
        }
    }
    @objc private func saveKey() {
        let v = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = EsnaligramKeyStore.saveAll(key: v, model: modelField.text, baseURL: urlField.text) {
            keyStatus = "❌ " + err
        } else {
            keyStatus = "✅ Kaydedildi."
            keyField.text = EsnaligramKeyStore.userKey
            modelField.text = EsnaligramKeyStore.userModel
            urlField.text = EsnaligramKeyStore.userBaseURL
        }
        keyField.resignFirstResponder()
        table.reloadSections(IndexSet(integer: 0), with: .none)
    }
    @objc private func clearKey() {
        let st = EsnaligramKeyStore.saveKey(nil)
        EsnaligramKeyStore.userModel = nil
        EsnaligramKeyStore.userBaseURL = nil
        if st != errSecSuccess { keyStatus = "❌ Silinemedi (OSStatus \(st))."; table.reloadSections(IndexSet(integer: 0), with: .none); return }
        keyField.text = ""; modelField.text = ""; urlField.text = ""
        keyStatus = "Silindi."
        table.reloadSections(IndexSet(integer: 0), with: .none)
    }
    @objc private func testKey() {
        guard let ep = typedEndpoint() else {
            keyStatus = "Anahtar yok."; table.reloadSections(IndexSet(integer: 0), with: .none); return
        }
        keyStatus = "Test ediliyor…"; table.reloadSections(IndexSet(integer: 0), with: .none)
        EsnaligramTranslator.testEndpoint(ep) { [weak self] r in
            guard let self else { return }
            self.keyStatus = "Test: " + r
            self.table.reloadSections(IndexSet(integer: 0), with: .none)
        }
    }
    public func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        guard ip.section == 3 else { return }
        EsnaligramTranslator.shared.manualTargetLanguage = ip.row == 0 ? nil : EsnaligramTranslator.languages[ip.row - 1].code
        t.reloadSections(IndexSet(integer: 3), with: .none)
    }
}
