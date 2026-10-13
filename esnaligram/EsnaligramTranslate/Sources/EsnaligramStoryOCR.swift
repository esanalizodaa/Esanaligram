import Foundation
import UIKit
import Vision

/// Hikâye görüntüsünden (uygulamanın kendi decode ettiği UIImage) metin okur.
/// Ekran görüntüsü almaz; korumayı kaldırmaz.
public enum EsnaligramStoryOCR {
    public static func recognize(_ image: UIImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage else { DispatchQueue.main.async { completion("") }; return }
        let req = VNRecognizeTextRequest { request, _ in
            let texts = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { completion(texts.joined(separator: "\n")) }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["tr", "en", "ru", "uk", "uz", "ar", "de", "fr", "es", "zh-Hans", "ja"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([req]) } catch { DispatchQueue.main.async { completion("") } }
        }
    }
}

/// Hikâye üzerine kapanabilir çeviri katmanı.
public final class EsnaligramStoryTranslateOverlay: UIView {
    private let label = UILabel()
    private let close = UIButton(type: .system)
    private let scroll = UIScrollView()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
        layer.cornerRadius = 14
        clipsToBounds = true
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .regular)
        close.setTitle("✕", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        close.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        addSubview(scroll); scroll.addSubview(label); addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }

    public func setText(_ text: String) { label.text = text; setNeedsLayout() }

    public override func layoutSubviews() {
        super.layoutSubviews()
        close.frame = CGRect(x: bounds.width - 44, y: 4, width: 40, height: 40)
        scroll.frame = bounds.inset(by: UIEdgeInsets(top: 40, left: 14, bottom: 14, right: 14))
        let size = label.sizeThatFits(CGSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
    }

    @objc private func dismissSelf() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in self.removeFromSuperview() }
    }

    public static func show(in host: UIView, text: String) {
        host.viewWithTag(913371)?.removeFromSuperview()
        let o = EsnaligramStoryTranslateOverlay()
        o.tag = 913371
        o.setText(text)
        o.alpha = 0
        let w = min(host.bounds.width - 32, 360)
        let h = min(host.bounds.height * 0.4, 280)
        o.frame = CGRect(x: (host.bounds.width - w) / 2, y: host.bounds.height - h - 100, width: w, height: h)
        host.addSubview(o)
        UIView.animate(withDuration: 0.25) { o.alpha = 1 }
    }
}

/// Hikâye "Çevir" butonu: OCR → DeepInfra → overlay.
public final class EsnaligramStoryTranslateButton: UIButton {
    public var getImage: (() -> UIImage?)?
    public var hostView: (() -> UIView?)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        setImage(UIImage(systemName: "text.viewfinder", withConfiguration: cfg), for: .normal)
        tintColor = .white
        accessibilityLabel = "Çevir"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        guard let image = getImage?() else {
            if let host = hostView?() { EsnaligramStoryTranslateOverlay.show(in: host, text: "Görüntü henüz yüklenmedi.") }
            return
        }
        isEnabled = false; alpha = 0.5
        EsnaligramStoryOCR.recognize(image) { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.isEnabled = true; self.alpha = 1
                if let host = self.hostView?() { EsnaligramStoryTranslateOverlay.show(in: host, text: "Metin bulunamadı.") }
                return
            }
            // Force Turkish / app language via manual target temporarily using translateOutgoing path
            let prev = EsnaligramTranslator.shared.manualTargetLanguage
            EsnaligramTranslator.shared.manualTargetLanguage = (Locale.current.languageCode ?? "tr")
            EsnaligramTranslator.shared.translate(trimmed, peerTexts: []) { result in
                EsnaligramTranslator.shared.manualTargetLanguage = prev
                self.isEnabled = true; self.alpha = 1
                let out: String
                switch result {
                case let .success(t): out = t
                case .failure(.targetUnknown):
                    // Fallback: translate to Turkish explicitly
                    out = trimmed
                case let .failure(.network(e)): out = "Çeviri hatası: \(e)"
                case .failure(.empty): out = "Çeviri boş döndü."
                }
                if case .failure(.targetUnknown) = result {
                    // Direct API call forcing tr
                    self.forceTranslateToAppLang(trimmed)
                    return
                }
                if let host = self.hostView?() { EsnaligramStoryTranslateOverlay.show(in: host, text: out) }
            }
        }
    }

    private func forceTranslateToAppLang(_ text: String) {
        let lang = Locale.current.languageCode ?? "tr"
        var req = URLRequest(url: URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!)
        req.httpMethod = "POST"; req.timeoutInterval = 40
        req.setValue("Bearer \(EsnaligramSecrets.deepInfraKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let sys = EsnaligramPrompt.system + "\n\nCONTEXT: Translate this message into language '\(lang)' (app UI language). Output only the translation."
        let body: [String: Any] = ["model": EsnaligramSecrets.model, "temperature": 0.2, "max_tokens": 1024,
                                   "messages": [["role": "system", "content": sys], ["role": "user", "content": text]]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let out: String
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
                out = t.trimmingCharacters(in: .whitespacesAndNewlines)
            } else { out = "Çeviri başarısız." }
            DispatchQueue.main.async {
                if let host = self?.hostView?() { EsnaligramStoryTranslateOverlay.show(in: host, text: out.isEmpty ? "Çeviri boş." : out) }
            }
        }.resume()
    }
}
