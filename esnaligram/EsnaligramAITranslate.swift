import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TranslateUI

/// Esnaligram: mesaja üç kez dokunma algılayıcı (çift dokunma Telegram'ın tepkisi olarak kalır).
final class EsnaligramTripleTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    var onTriple: ((CGPoint) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        self.numberOfTapsRequired = 3
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        self.delegate = self
        self.addTarget(self, action: #selector(self.fired))
    }

    @objc private func fired() {
        if self.state == .ended, let view = self.view {
            self.onTriple?(self.location(in: view))
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

final class EsnaligramAIBridge {
    static weak var current: ChatControllerImpl?
}

extension ChatControllerImpl {
    func esnInstallTripleTap() {
        EsnaligramAIBridge.current = self
        let historyView = self.chatDisplayNode.historyNode.view
        if historyView.gestureRecognizers?.contains(where: { $0 is EsnaligramTripleTapRecognizer }) == true {
            return
        }
        let recognizer = EsnaligramTripleTapRecognizer()
        recognizer.onTriple = { [weak self, weak historyView] point in
            guard let self, let historyView else {
                return
            }
            var found: EngineMessage.Id?
            self.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                if found == nil, let item = itemNode.item {
                    let frame = itemNode.view.convert(itemNode.view.bounds, to: historyView)
                    if frame.contains(point) {
                        found = item.message.id
                    }
                }
            }
            if let found {
                self.esnAITranslate(messageId: found)
            }
        }
        historyView.addGestureRecognizer(recognizer)
    }

    func esnAITranslate(messageId: EngineMessage.Id) {
        var toLang: String = self.presentationInterfaceState.translationState?.toLang ?? self.presentationData.strings.baseLanguageCode
        if toLang.hasSuffix("-raw") {
            toLang = String(toLang.dropLast(4))
        }
        toLang = normalizeTranslationLanguage(toLang)
        let _ = (esnaligramAITranslateMessage(postbox: self.context.account.postbox, messageId: messageId, toLang: toLang)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] text in
            guard let self else {
                return
            }
            let alert = UIAlertController(title: "Yapay zeka çevirisi", message: text ?? "Çeviri yapılamadı (API anahtarı veya bağlantı sorunu).", preferredStyle: .alert)
            if let text {
                alert.addAction(UIAlertAction(title: "Kopyala", style: .default, handler: { _ in
                    UIPasteboard.general.string = text
                }))
            }
            alert.addAction(UIAlertAction(title: "Tamam", style: .cancel, handler: nil))
            var top = self.view.window?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            top?.present(alert, animated: true, completion: nil)
        })
    }
}
