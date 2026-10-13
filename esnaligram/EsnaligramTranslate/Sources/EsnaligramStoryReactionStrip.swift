import Foundation
import UIKit

/// Esnaligram: hikâyede yanıt alanı yerine iki satır büyük tepki düğmesi (en çok kullanılanlar önce).
public final class EsnaligramStoryReactionStrip: UIView {
    public var onSelect: ((String) -> Void)?
    public var onMore: ((UIView) -> Void)?
    private let moreButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private var emojis: [String] = []
    private var buttons: [UIButton] = []
    public static let rowHeight: CGFloat = 48.0
    public static let totalHeight: CGFloat = 104.0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        addSubview(scroll)
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        moreButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: cfg), for: .normal)
        moreButton.tintColor = .white
        moreButton.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        moreButton.layer.cornerRadius = 23.0
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        scroll.addSubview(moreButton)
    }
    @objc private func moreTapped() { onMore?(moreButton) }
    required init?(coder: NSCoder) { fatalError() }

    public func update(emojis newEmojis: [String], selected: String?) {
        let limited = Array(newEmojis.prefix(11))
        if limited != emojis {
            emojis = limited
            for b in buttons { b.removeFromSuperview() }
            buttons = []
            for (i, e) in emojis.enumerated() {
                let b = UIButton(type: .custom)
                b.setTitle(e, for: .normal)
                b.titleLabel?.font = UIFont.systemFont(ofSize: 32.0)
                b.layer.cornerRadius = 23.0
                b.tag = i
                b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
                scroll.addSubview(b)
                buttons.append(b)
            }
            setNeedsLayout()
        }
        for (i, b) in buttons.enumerated() {
            b.backgroundColor = emojis[i] == selected ? UIColor.white.withAlphaComponent(0.35) : UIColor.black.withAlphaComponent(0.25)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let spacing: CGFloat = 8.0
        let size: CGFloat = min(48.0, floor((bounds.width - 16.0 - spacing * 5.0) / 6.0))
        let totalW = size * 6.0 + spacing * 5.0
        let x0 = floor((bounds.width - totalW) / 2.0)
        var all: [UIView] = buttons
        all.append(moreButton)
        for (i, b) in all.enumerated() {
            let col = i % 6
            let row = i / 6
            b.frame = CGRect(x: x0 + CGFloat(col) * (size + spacing), y: 2.0 + CGFloat(row) * (size + spacing), width: size, height: size)
            b.layer.cornerRadius = size / 2.0
        }
        scroll.contentSize = bounds.size
    }

    @objc private func tapped(_ b: UIButton) {
        guard b.tag < emojis.count else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(withDuration: 0.1, animations: { b.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }, completion: { _ in
            UIView.animate(withDuration: 0.15) { b.transform = .identity }
        })
        onSelect?(emojis[b.tag])
    }
}
