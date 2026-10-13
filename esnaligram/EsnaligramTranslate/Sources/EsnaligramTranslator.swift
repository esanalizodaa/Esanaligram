import Foundation
import UIKit
import NaturalLanguage

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

    public enum TranslateError: Error { case targetUnknown, network(String), empty }

    public static let languages: [(code: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("uz", "Oʻzbek"), ("kk", "Қазақ"), ("uk", "Українська"),
        ("az", "Azərbaycan"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("ar", "العربية"), ("fa", "فارسی"), ("ky", "Кыргыз"), ("tg", "Тоҷикӣ"), ("pl", "Polski"),
        ("pt", "Português"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"), ("tr", "Türkçe")
    ]

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

    public func translate(_ text: String, peerTexts: [String], completion: @escaping (Result<String, TranslateError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.failure(.empty)); return }
        let isTurkish = Self.detect(trimmed) == "tr"
        var context: String
        if isTurkish {
            guard let target = resolveTarget(peerTexts: peerTexts) else { completion(.failure(.targetUnknown)); return }
            context = "CONTEXT: The other person's language is '\(target)'. Translate the user's message into this language."
        } else {
            context = "CONTEXT: Translate this message into natural Turkish."
        }
        if !peerTexts.isEmpty {
            context += "\nRecent messages from the other person (context only, do not translate):\n" + peerTexts.suffix(6).joined(separator: "\n")
        }
        var sys = EsnaligramPrompt.system
        let extra = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { sys += "\n\nADDITIONAL USER INSTRUCTIONS:\n" + extra }
        sys += "\n\n" + context

        let body: [String: Any] = [
            "model": EsnaligramSecrets.model,
            "temperature": 0.3,
            "max_tokens": 1024,
            "messages": [["role": "system", "content": sys], ["role": "user", "content": trimmed]]
        ]
        var req = URLRequest(url: URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("Bearer \(EsnaligramSecrets.deepInfraKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, error in
            let result: Result<String, TranslateError>
            if let error = error {
                result = .failure(.network(error.localizedDescription))
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                      let out = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
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
    public var getPeerTexts: ((@escaping ([String]) -> Void) -> Void)?
    public var presentController: ((UIViewController) -> Void)?

    private var undoText: String?
    private var lastTranslated: String?
    private let spinner = UIActivityIndicatorView(style: .medium)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        setImage(UIImage(systemName: "character.bubble", withConfiguration: cfg), for: .normal)
        accessibilityLabel = "Çevir"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        spinner.hidesWhenStopped = true
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func layoutSubviews() { super.layoutSubviews(); spinner.center = CGPoint(x: bounds.midX, y: bounds.midY) }

    public func updateColor(_ color: UIColor) { tintColor = color; spinner.color = color }

    @objc private func tapped() {
        let current = getText?() ?? ""
        if let undo = undoText, current == lastTranslated {
            setText?(undo); undoText = nil; lastTranslated = nil; return
        }
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !spinner.isAnimating else { return }
        setLoading(true)
        let run: ([String]) -> Void = { [weak self] peerTexts in
            EsnaligramTranslator.shared.translate(current, peerTexts: peerTexts) { result in
                guard let self else { return }
                self.setLoading(false)
                switch result {
                case let .success(out):
                    self.undoText = current; self.lastTranslated = out; self.setText?(out)
                case .failure(.targetUnknown):
                    self.showLanguagePicker(message: "Karşı tarafın dili algılanamadı. Dili seç, sonra tekrar Çevir'e bas.")
                case .failure(.empty):
                    break
                case let .failure(.network(e)):
                    self.alert("Çeviri hatası", e)
                }
            }
        }
        if let getPeerTexts { getPeerTexts { texts in DispatchQueue.main.async { run(texts) } } } else { run([]) }
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
        view.addSubview(table)
    }
    @objc private func done() {
        EsnaligramTranslator.shared.extraPrompt = promptView.text ?? ""
        dismiss(animated: true)
    }
    public func numberOfSections(in t: UITableView) -> Int { 3 }
    public func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        if s == 0 { return 1 } // auto-translate toggle
        if s == 1 { return 1 } // prompt
        return EsnaligramTranslator.languages.count + 1
    }
    public func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        if s == 0 { return "Gelen mesajlar" }
        if s == 1 { return "Ek prompt (isteğe bağlı)" }
        return "Giden çeviri — hedef dil"
    }
    public func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        if s == 0 { return "Açıkken gelen mesajlar uygulama diline çevrilir. Orijinal için çeviriye dokun." }
        if s == 1 { return message }
        return nil
    }
    public func tableView(_ t: UITableView, heightForRowAt ip: IndexPath) -> CGFloat { ip.section == 1 ? 120 : 44 }
    public func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: nil)
        if ip.section == 0 {
            c.textLabel?.text = "Otomatik çevir (gelen)"
            let sw = UISwitch()
            if UserDefaults.standard.object(forKey: "esn.autoTranslate") == nil { sw.isOn = true }
            else { sw.isOn = UserDefaults.standard.bool(forKey: "esn.autoTranslate") }
            sw.addTarget(self, action: #selector(autoChanged(_:)), for: .valueChanged)
            c.accessoryView = sw; c.selectionStyle = .none
            return c
        }
        if ip.section == 1 {
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
    @objc private func autoChanged(_ sw: UISwitch) {
        UserDefaults.standard.set(sw.isOn, forKey: "esn.autoTranslate")
    }
    public func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        guard ip.section == 2 else { return }
        EsnaligramTranslator.shared.manualTargetLanguage = ip.row == 0 ? nil : EsnaligramTranslator.languages[ip.row - 1].code
        t.reloadSections(IndexSet(integer: 2), with: .none)
    }
}
