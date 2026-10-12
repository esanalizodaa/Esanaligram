#!/usr/bin/env python3
"""Esnaligram yamalarını Telegram-iOS (release-13.0.0) checkout'una uygular.
Kullanım: python3 scripts/apply.py <telegram-ios-dizini>
Her düzenleme sabit bir metne bağlıdır; metin bulunamazsa script hata verir (sessizce bozmaz)."""
import os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TG = os.path.abspath(sys.argv[1])

def edit(rel, old, new, count=1):
    p = os.path.join(TG, rel)
    s = open(p, encoding="utf-8").read()
    n = s.count(old)
    if n < 1 or (count and n != count):
        sys.exit(f"[HATA] {rel}: beklenen metin {n} kez bulundu (beklenen {count or '>=1'}):\n{old[:200]}")
    s = s.replace(old, new) if not count else s.replace(old, new, count)
    open(p, "w", encoding="utf-8").write(s)
    print(f"[ok] {rel}")

# 1) Çeviri modülünü kopyala + anahtarı enjekte et
dst = os.path.join(TG, "submodules/EsnaligramTranslate")
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(os.path.join(ROOT, "esnaligram/EsnaligramTranslate"), dst)
key = os.environ.get("DEEPINFRA_API_KEY", "")
if not key:
    local = os.path.join(ROOT, "config/local.env")
    if os.path.exists(local):
        m = re.search(r"DEEPINFRA_API_KEY=(\S+)", open(local).read())
        key = m.group(1) if m else ""
if not key:
    sys.exit("[HATA] DEEPINFRA_API_KEY yok (GitHub secret veya config/local.env)")
sp = os.path.join(dst, "Sources/EsnaligramSecrets.swift")
open(sp, "w").write(open(sp).read().replace("__DEEPINFRA_API_KEY__", key))
print("[ok] EsnaligramTranslate kopyalandı, anahtar enjekte edildi")

# 2) Sekmeler: yalnızca Sohbetler (sol) + Profil (sağ). Kişiler ve Aramalar kaldırıldı.
#    Profil sekmesi upstream'de zaten "Ayarlar" PeerInfoScreen'idir; uzun basınca hesap değiştirme menüsü upstream özelliğidir.
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

# 3) Giriş çubuğu: sticker butonunun soluna çeviri butonu
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
                completion([])
                return
            }
            let _ = (context.account.postbox.transaction { transaction -> [String] in
                var result: [String] = []
                transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 40, { message in
                    if message.flags.contains(.Incoming) && !message.text.isEmpty {
                        result.append(message.text)
                    }
                    return result.count < 15
                })
                return Array(result.reversed())
            }
            |> deliverOnMainQueue).start(next: { texts in
                completion(texts)
            })
        }
        b.presentController = { [weak self] controller in
            var top = self?.view.window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            top?.present(controller, animated: true)
        }
        return b
    }()
""")
# genişlik hesabına çeviri butonunu ekle (metin altına girmesin)
edit(IP, "        var accessoryButtonsWidth: CGFloat = 0.0\n",
         "        var accessoryButtonsWidth: CGFloat = 36.0 // Esnaligram çeviri butonu\n", count=0)
# yerleşim: accessory butonları sağdan sola dizildikten sonra, en solda çeviri butonu
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

# 4) Uygulama adı
edit("Telegram/BUILD", "    <key>CFBundleDisplayName</key>\n    <string>Telegram</string>",
                       "    <key>CFBundleDisplayName</key>\n    <string>Esnaligram</string>", count=0)
print("Tüm Esnaligram yamaları uygulandı.")
