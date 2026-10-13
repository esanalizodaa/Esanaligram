#!/usr/bin/env python3
"""Esnaligram yamalarını Telegram-iOS (release-13.0.0) checkout'una uygular."""
import os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TG = os.path.abspath(sys.argv[1])

def edit(rel, old, new, count=1):
    p = os.path.join(TG, rel)
    s = open(p, encoding="utf-8").read()
    n = s.count(old)
    if n < 1 or (count is not None and count != 0 and n != count):
        if count == 0 and n >= 1:
            pass
        else:
            sys.exit(f"[HATA] {rel}: metin {n} kez (beklenen {count or '>=1'}):\n{old[:220]}")
    if count == 0:
        s = s.replace(old, new)
    else:
        s = s.replace(old, new, count if count else n)
    open(p, "w", encoding="utf-8").write(s)
    print(f"[ok] {rel}")

def inject_key(path, key):
    s = open(path, encoding="utf-8").read()
    if "__DEEPINFRA_API_KEY__" not in s:
        sys.exit(f"[HATA] {path}: placeholder yok")
    open(path, "w", encoding="utf-8").write(s.replace("__DEEPINFRA_API_KEY__", key))

key = os.environ.get("DEEPINFRA_API_KEY", "")
if not key:
    local = os.path.join(ROOT, "config/local.env")
    if os.path.exists(local):
        m = re.search(r"DEEPINFRA_API_KEY=(\S+)", open(local).read())
        key = m.group(1) if m else ""
if not key:
    sys.exit("[HATA] DEEPINFRA_API_KEY yok")

# --- 1) Modüller ---
dst = os.path.join(TG, "submodules/EsnaligramTranslate")
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(os.path.join(ROOT, "esnaligram/EsnaligramTranslate"), dst)
inject_key(os.path.join(dst, "Sources/EsnaligramSecrets.swift"), key)
print("[ok] EsnaligramTranslate")

core_dst = os.path.join(TG, "submodules/TelegramCore/Sources/TelegramEngine/Messages/EsnaligramDeepInfraTranslate.swift")
shutil.copy2(os.path.join(ROOT, "esnaligram/EsnaligramDeepInfraTranslate.swift"), core_dst)
inject_key(core_dst, key)
print("[ok] EsnaligramDeepInfraTranslate → TelegramCore")

# --- 2) Sekmeler ---
RC = "submodules/TelegramUI/Sources/TelegramRootController.swift"
edit(RC, """        controllers.append(contactsController)
        
        if showCallsTab {
            controllers.append(callListController)
        }
        controllers.append(chatListController)""",
"""        // Esnaligram: Kişiler ve Aramalar sekmeleri kaldırıldı
        controllers.append(chatListController)""")
edit(RC, "selectedIndex: restoreSettignsController != nil ? (controllers.count - 1) : (controllers.count - 2))",
         "selectedIndex: restoreSettignsController != nil ? 1 : 0)")
edit(RC, """        controllers.append(self.contactsController!)
        if showCallsTab {
            controllers.append(self.callListController!)
        }
        controllers.append(self.chatListController!)""",
"""        controllers.append(self.chatListController!)""")

# --- 3) Giden çeviri butonu ---
IP = "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
edit(IP, "import Foundation\n", "import Foundation\nimport EsnaligramTranslate\nimport Postbox\n")
edit(IP, "    private var accessoryItemButtons: [(ChatTextInputAccessoryItem, AccessoryItemIconButton)] = []\n",
"""    private var accessoryItemButtons: [(ChatTextInputAccessoryItem, AccessoryItemIconButton)] = []
    private lazy var esnTranslateButton: EsnaligramTranslateButton = {
        let b = EsnaligramTranslateButton(frame: .zero)
        b.getText = { [weak self] in
            return self?.presentationInterfaceState?.interfaceState.effectiveInputState.inputText.string ?? ""
        }
        b.setText = { [weak self] text in
            self?.interfaceInteraction?.updateTextInputStateAndMode { _, inputMode in
                return (ChatTextInputState(inputText: NSAttributedString(string: text)), inputMode)
            }
        }
        b.getPeerTexts = { [weak self] completion in
            guard let self, let context = self.context, let peerId = self.presentationInterfaceState?.chatLocation.peerId else {
                completion([]); return
            }
            let _ = (context.account.postbox.transaction { transaction -> [String] in
                var result: [String] = []
                transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 60, { message in
                    if !message.text.isEmpty { result.append((message.flags.contains(.Incoming) ? "them: " : "me: ") + message.text) }
                    return result.count < 20
                })
                return Array(result.reversed())
            } |> deliverOnMainQueue).start(next: { completion($0) })
        }
        b.presentController = { [weak self] controller in
            var top = self?.view.window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            top?.present(controller, animated: true)
        }
        return b
    }()
""")
edit(IP, "        var accessoryButtonsWidth: CGFloat = 0.0\n",
         "        var accessoryButtonsWidth: CGFloat = 36.0 // Esnaligram çeviri butonu\n", count=0)
edit(IP, """            switch item.key {
            case .input:
                nextButtonTopRight.x += 2.0
            default:
                break
            }
        }
        
        self.currentTextInputBackgroundWidthOffset = textInputBackgroundWidthOffset
""", """            switch item.key {
            case .input:
                nextButtonTopRight.x += 2.0
            default:
                break
            }
        }
        
        // Esnaligram: çeviri butonu (sticker butonunun solunda)
        do {
            let esnSize = CGSize(width: 36.0, height: minimalInputHeight)
            let esnFrame = CGRect(origin: CGPoint(x: nextButtonTopRight.x - esnSize.width, y: nextButtonTopRight.y), size: esnSize)
            if self.esnTranslateButton.superview == nil {
                self.textInputContainerBackgroundView.contentView.addSubview(self.esnTranslateButton)
                self.esnTranslateButton.frame = esnFrame
            } else {
                transition.updateFrame(layer: self.esnTranslateButton.layer, frame: esnFrame)
            }
            self.esnTranslateButton.updateColor(interfaceState.theme.chat.inputPanel.panelControlColor)
            transition.updateAlpha(layer: self.esnTranslateButton.layer, alpha: audioRecordingItemsAlpha)
            nextButtonTopRight.x -= esnSize.width
        }
        
        self.currentTextInputBackgroundWidthOffset = textInputBackgroundWidthOffset
""")
edit("submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/BUILD",
     '    deps = [\n        "//submodules/Display",\n',
     '    deps = [\n        "//submodules/EsnaligramTranslate",\n        "//submodules/Postbox",\n        "//submodules/Display",\n')

# --- 4) Uygulama adı ---
edit("Telegram/BUILD", "    <key>CFBundleDisplayName</key>\n    <string>Telegram</string>",
                       "    <key>CFBundleDisplayName</key>\n    <string>Esnaligram</string>", count=0)

# --- 5) Hesap limiti kaldır ---
# AccountUtils may not be present until full clone; patch when present
AU = "submodules/AccountUtils/Sources/AccountUtils.swift"
if os.path.exists(os.path.join(TG, AU)):
    edit(AU, "public let maximumNumberOfAccounts = 3\npublic let maximumPremiumNumberOfAccounts = 4\n",
             "public let maximumNumberOfAccounts = 50\npublic let maximumPremiumNumberOfAccounts = 50\n")

def uncap_accounts(rel, snippet_start="var maximumAvailableAccounts: Int = 3"):
    p = os.path.join(TG, rel)
    if not os.path.exists(p):
        print(f"[skip] {rel}"); return
    s = open(p, encoding="utf-8").read()
    # Replace the whole if count >= maximumAvailableAccounts { Premium... } else { beginNewAuth } with just beginNewAuth
    # Safer: set maximumAvailableAccounts = 50 always
    old = "var maximumAvailableAccounts: Int = 3"
    if old not in s:
        print(f"[skip] {rel}: pattern yok"); return
    s = s.replace("var maximumAvailableAccounts: Int = 3", "var maximumAvailableAccounts: Int = 50")
    s = s.replace("maximumAvailableAccounts = 4", "maximumAvailableAccounts = 50")
    open(p, "w", encoding="utf-8").write(s)
    print(f"[ok] {rel} (hesap limiti)")

uncap_accounts("submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift")
uncap_accounts("submodules/SettingsUI/Sources/LogoutOptionsController.swift")
uncap_accounts("submodules/SettingsUI/Sources/DeleteAccountOptionsController.swift")

# canAddAccounts comparisons against maximumNumberOfAccounts — with 50 it's fine
for rel in [
    "submodules/SettingsUI/Sources/DeleteAccountOptionsController.swift",
    "submodules/SettingsUI/Sources/Search/SettingsSearchableItems.swift",
]:
    p = os.path.join(TG, rel)
    if os.path.exists(p):
        s = open(p, encoding="utf-8").read()
        if "maximumNumberOfAccounts" in s:
            print(f"[ok] {rel} (maximumNumberOfAccounts=50 ile serbest)")


# --- 6) Gelen otomatik çeviri ---
edit("submodules/TranslateUI/Sources/Translate.swift",
"""public func canTranslateChats(context: AccountContext) -> Bool {
    let translationConfiguration = TranslationConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
    var chatTranslationAvailable = true
    switch translationConfiguration.auto {
    case .system:
        if #available(iOS 18.0, *) {
        } else {
            chatTranslationAvailable = false
        }
    case .alternative, .disabled:
        chatTranslationAvailable = false
    default:
        break
    }
    return chatTranslationAvailable
}""",
"""public func canTranslateChats(context: AccountContext) -> Bool {
    // Esnaligram: her zaman açık (DeepInfra); peer tipine bakılmaz
    return true
}""")

CT = "submodules/TranslateUI/Sources/ChatTranslation.swift"
edit(CT,
"""        |> mapToSignal { settings, autoTranslateEnabled in
            if !settings.translateChats && !autoTranslateEnabled {
                return .single(nil)
            }
""",
"""        |> mapToSignal { settings, autoTranslateEnabled in
            // Esnaligram: global otomatik çeviri (varsayılan açık)
            if !EsnaligramDeepInfra.autoTranslateEnabled {
                if !settings.translateChats && !autoTranslateEnabled {
                    return .single(nil)
                }
            }
""")
edit(CT,
"""                            let isEnabled: Bool
                            if let currentIsEnabled = cached?.isEnabled {
                                isEnabled = currentIsEnabled
                            } else if autoTranslateEnabled {
                                isEnabled = true
                            } else {
                                isEnabled = false
                            }
""",
"""                            let isEnabled: Bool
                            if let currentIsEnabled = cached?.isEnabled {
                                isEnabled = currentIsEnabled
                            } else if EsnaligramDeepInfra.autoTranslateEnabled || autoTranslateEnabled {
                                isEnabled = true
                            } else {
                                isEnabled = false
                            }
""")

HL = "submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
edit(HL,
"                if let translationState, (isPremium || autoTranslate)  && translationState.isEnabled {",
"                if let translationState, translationState.isEnabled, (isPremium || autoTranslate || true) { // Esnaligram: Premium şartı yok")

# Translate.swift: replace functions cleanly
TR = "submodules/TelegramCore/Sources/TelegramEngine/Messages/Translate.swift"
tr_path = os.path.join(TG, TR)
tr = open(tr_path, encoding="utf-8").read()

def replace_func(src, sig_prefix, new_body):
    idx = src.find(sig_prefix)
    if idx < 0:
        sys.exit(f"[HATA] Translate.swift: {sig_prefix[:70]} yok")
    rest = src[idx+1:]
    m = re.search(r'\n(?:func |private func |public func |enum |final class |class |struct |public enum |public struct |public final class )', rest)
    if not m:
        sys.exit(f"[HATA] Translate.swift: {sig_prefix[:40]} sonu yok")
    end = idx + 1 + m.start() + 1
    return src[:idx] + new_body.rstrip() + "\n\n" + src[end:]

tr = replace_func(tr, "func _internal_translate(network: Network, text: String",
"""func _internal_translate(network: Network, text: String, toLang: String, entities: [MessageTextEntity] = [], tone: TranslationTone = .neutral, peer: Api.InputPeer? = nil, messageId: Int32? = nil) -> Signal<(String, [MessageTextEntity])?, TranslationError> {
    let _ = (network, tone, peer, messageId)
    return EsnaligramDeepInfra.translateSignal(text: text, entities: entities, toLang: toLang)
    |> map(Optional.init)
    |> castError(TranslationError.self)
}
""")
tr = replace_func(tr, "func _internal_translateTexts(network: Network, texts:",
"""func _internal_translateTexts(network: Network, texts: [(String, [MessageTextEntity])], toLang: String, tone: TranslationTone = .neutral) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    let _ = (network, tone)
    return EsnaligramDeepInfra.translateTextsSignal(texts: texts, toLang: toLang)
    |> castError(TranslationError.self)
}
""")

old_peer = (
"            } else {\n"
"                msgs = account.network.request(Api.functions.messages.translateText(flags: flags, peer: inputPeer, id: id, text: nil, toLang: toLang, tone: tone != .neutral ? tone.rawValue : nil))\n"
"                |> map(Optional.init)\n"
"                |> mapError { error -> TranslationError in\n"
"                    if error.errorDescription.hasPrefix(\"FLOOD_WAIT\") {\n"
"                        return .limitExceeded\n"
"                    } else if error.errorDescription == \"MSG_ID_INVALID\" {\n"
"                        return .invalidMessageId\n"
"                    } else if error.errorDescription == \"INPUT_TEXT_EMPTY\" {\n"
"                        return .textIsEmpty\n"
"                    } else if error.errorDescription == \"INPUT_TEXT_TOO_LONG\" {\n"
"                        return .textTooLong\n"
"                    } else if error.errorDescription == \"TO_LANG_INVALID\" {\n"
"                        return .invalidLanguage\n"
"                    } else {\n"
"                        return .generic\n"
"                    }\n"
"                }\n"
"            }\n"
)
new_peer = (
"            } else {\n"
"                // Esnaligram: DeepInfra — entity korumalı; her sohbet türünde\n"
"                msgs = account.postbox.transaction { transaction -> [MessageId: (String, [MessageTextEntity], String)] in\n"
"                    var texts: [MessageId: (String, [MessageTextEntity], String)] = [:]\n"
"                    var recent: [Message] = []\n"
"                    if EsnaligramDeepInfra.incomingContextEnabled, let firstId = plainMessageIds.first {\n"
"                        transaction.scanTopMessages(peerId: firstId.peerId, namespace: firstId.namespace, limit: 120, { m in\n"
"                            if !m.text.isEmpty { recent.append(m) }\n"
"                            return recent.count < 120\n"
"                        })\n"
"                    }\n"
"                    for messageId in plainMessageIds {\n"
"                        if let message = transaction.getMessage(messageId) {\n"
"                            let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []\n"
"                            var lines: [String] = []\n"
"                            for m in recent where m.id.namespace == messageId.namespace && m.id.id < messageId.id {\n"
"                                lines.append((m.flags.contains(.Incoming) ? \"them: \" : \"me: \") + m.text)\n"
"                                if lines.count >= 20 { break }\n"
"                            }\n"
"                            texts[message.id] = (message.text, entities, EsnaligramDeepInfra.contextString(Array(lines.reversed())))\n"
"                        }\n"
"                    }\n"
"                    return texts\n"
"                }\n"
"                |> castError(TranslationError.self)\n"
"                |> mapToSignal { messageTexts -> Signal<Api.messages.TranslatedText?, TranslationError> in\n"
"                    var items: [(String, [MessageTextEntity], String, String)] = []\n"
"                    for messageId in plainMessageIds {\n"
"                        let t: (String, [MessageTextEntity], String) = messageTexts[messageId] ?? (\"\", [MessageTextEntity](), \"\")\n"
"                        items.append((t.0, t.1, t.2, \"\\(messageId.peerId.toInt64()):\\(messageId.namespace):\\(messageId.id)\"))\n"
"                    }\n"
"                    return EsnaligramDeepInfra.translateMessagesSignal(items: items, toLang: toLang)\n"
"                    |> castError(TranslationError.self)\n"
"                    |> map { results -> Api.messages.TranslatedText? in\n"
"                        var apiResults: [Api.TextWithEntities] = []\n"
"                        for (text, ents) in results {\n"
"                            apiResults.append(.textWithEntities(.init(text: text, entities: apiEntitiesFromMessageTextEntities(ents, associatedPeers: SimpleDictionary()))))\n"
"                        }\n"
"                        return .translateResult(.init(result: apiResults))\n"
"                    }\n"
"                }\n"
"            }\n"
)
if old_peer not in tr:
    sys.exit("[HATA] peer translate path bulunamadı")
tr = tr.replace(old_peer, new_peer, 1)
open(tr_path, "w", encoding="utf-8").write(tr)
print("[ok] Translate.swift DeepInfra")

# --- 7) Hikâye Çevir ---
SIV = "submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemImageView.swift"
edit(SIV,
"""    private(set) var isContentLoaded: Bool = false
    var didLoadContents: (() -> Void)?
""",
"""    private(set) var isContentLoaded: Bool = false
    var didLoadContents: (() -> Void)?
    /// Esnaligram: decode edilmiş medya (ekran görüntüsü değil; korumayı kaldırmaz)
    func currentImageForOCR() -> UIImage? { self.contentView.image }
""")

SIC = "submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemContentComponent.swift"
edit(SIC,
"""    final class View: StoryContentItem.View {
""",
"""    final class View: StoryContentItem.View {
        // Esnaligram: hikâye karesinden OCR (ekran görüntüsü / koruma bypass değil)
        func currentImageForOCR() -> UIImage? {
            if let img = self.imageView.currentImageForOCR() { return img }
            return nil
        }
""")

SSC = "submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/StoryItemSetContainerComponent.swift"
edit(SSC, "import Foundation\n", "import Foundation\nimport EsnaligramTranslate\n")
edit(SSC,
"""        let closeButton: HighlightableButton
        let closeButtonIconView: UIImageView
""",
"""        let closeButton: HighlightableButton
        let closeButtonIconView: UIImageView
        let esnStoryTranslateButton = EsnaligramStoryTranslateButton(frame: .zero)
""")
edit(SSC,
"""            self.closeButton.addSubview(self.closeButtonIconView)
            self.overlayContainerView.addSubview(self.closeButton)
            self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
""",
"""            self.closeButton.addSubview(self.closeButtonIconView)
            self.overlayContainerView.addSubview(self.closeButton)
            self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
            self.esnStoryTranslateButton.getImage = { [weak self] in
                guard let self, let component = self.component else { return nil }
                guard let visible = self.visibleItems[component.slice.item.id],
                      let view = visible.view.view as? StoryItemContentComponent.View else { return nil }
                return view.currentImageForOCR()
            }
            self.esnStoryTranslateButton.hostView = { [weak self] in self?.overlayContainerView }
            self.overlayContainerView.addSubview(self.esnStoryTranslateButton)
""")
edit(SSC,
"""                transition.setFrame(view: self.closeButton, frame: closeButtonFrame)
                transition.setAlpha(view: self.closeButton, alpha: (component.hideUI || self.isEditingStory || component.isEmbeddedInCamera) ? 0.0 : 1.0)
                transition.setFrame(view: self.closeButtonIconView, frame: CGRect(origin: CGPoint(x: floor((closeButtonFrame.width - image.size.width) * 0.5), y: floor((closeButtonFrame.height - image.size.height) * 0.5)), size: image.size))
                headerRightOffset -= 51.0
            }
""",
"""                transition.setFrame(view: self.closeButton, frame: closeButtonFrame)
                transition.setAlpha(view: self.closeButton, alpha: (component.hideUI || self.isEditingStory || component.isEmbeddedInCamera) ? 0.0 : 1.0)
                transition.setFrame(view: self.closeButtonIconView, frame: CGRect(origin: CGPoint(x: floor((closeButtonFrame.width - image.size.width) * 0.5), y: floor((closeButtonFrame.height - image.size.height) * 0.5)), size: image.size))
                headerRightOffset -= 51.0
                let esnFrame = CGRect(origin: CGPoint(x: closeButtonFrame.minX - 50.0, y: closeButtonFrame.minY), size: CGSize(width: 50.0, height: 64.0))
                transition.setFrame(view: self.esnStoryTranslateButton, frame: esnFrame)
                transition.setAlpha(view: self.esnStoryTranslateButton, alpha: (component.hideUI || self.isEditingStory || component.isEmbeddedInCamera) ? 0.0 : 1.0)
                headerRightOffset -= 50.0
            }
""")
edit("submodules/TelegramUI/Components/Stories/StoryContainerScreen/BUILD",
     '    deps = [\n        "//submodules/UrlWhitelist",\n',
     '    deps = [\n        "//submodules/EsnaligramTranslate",\n        "//submodules/UrlWhitelist",\n')

print("Tüm Esnaligram yamaları uygulandı.")
