import Cocoa

/// `MUXMAESTRO_SETTINGS_SELFTEST=1`: the Settings window end to end in the real
/// app. It opens the window from the app menu, picks Codex and a model, edits
/// and saves the instructions, restarts the Maestro and goes through the tabs.
/// Run it through `scripts/settings-selftest.sh`, which gives the app a scratch
/// home, a private tmux server and its own defaults domain, and then reads the
/// Maestro pane. `MUXMAESTRO_SETTINGS_SHOTS` names a directory for PNGs.
enum SettingsSelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["MUXMAESTRO_SETTINGS_SELFTEST"] == "1" else { return }
        Run(shots: env["MUXMAESTRO_SETTINGS_SHOTS"]).start()
    }

    private final class Run {
        let shots: String?
        var lines = ["SETTINGS SELFTEST"]
        var ok = true
        var steps: [() -> Void] = []

        init(shots: String?) { self.shots = shots }

        func start() {
            steps = [open, defaults, edit, saved, restart, phone, tools, finish]
            next(after: 2)
        }

        private func next(after delay: TimeInterval = 1) {
            guard !steps.isEmpty else { return }
            let step = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }

        private func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            ok = ok && passed
            lines.append("  \(passed ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  \(detail)")")
        }

        // MARK: The window and what is in it

        private var window: NSWindow? {
            NSApp.windows.first { $0.windowController is SettingsWindowController }
        }

        private func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

        private func find<T: NSView>(_ type: T.Type) -> T? {
            window?.contentView.flatMap(all)?.first { $0 is T } as? T
        }

        /// The Instructions box. The Model box has a text view too, while it is edited.
        private var editor: NSTextView? {
            window?.contentView.flatMap(all)?
                .first { ($0 as? NSTextView)?.isFieldEditor == false } as? NSTextView
        }

        private func button(_ title: String) -> NSButton? {
            window?.contentView.flatMap(all)?
                .first { ($0 as? NSButton)?.title == title && !($0 is NSPopUpButton) } as? NSButton
        }

        /// The whole window, title bar and tabs included.
        private func shot(_ file: String) {
            guard let shots, let view = window?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: shots).appendingPathComponent(file))
        }

        private func selectTab(_ title: String) {
            guard let item = window?.toolbar?.items.first(where: { $0.label == title }),
                  let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }

        private var home: URL? { ManagerHome.defaultHome() }

        // MARK: Steps

        private func open() {
            let item = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first { $0.title == "Settings…" }
            check("the app menu has Settings… on ⌘,", item?.keyEquivalent == ",")
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            next()
        }

        private func defaults() {
            check("the window opens on Maestro", window?.isVisible == true && window?.title == "Maestro",
                  window?.title ?? "no window")
            check("tabs", window?.toolbar?.items.map(\.label) == ["Maestro", "Phone", "Tools"],
                  "\(window?.toolbar?.items.map(\.label) ?? [])")
            check("Provider starts as Claude", find(NSPopUpButton.self)?.titleOfSelectedItem == "Claude")
            check("Model starts empty", find(NSComboBox.self)?.stringValue == "")
            check("Instructions show the seeded file",
                  editor?.string.contains("## Prime directives") == true)
            check("Save is off with nothing edited", button("Save")?.isEnabled == false)
            shot("1-maestro-default.png")
            next(after: 0.2)
        }

        private func edit() {
            if let provider = find(NSPopUpButton.self) {
                provider.selectItem(withTitle: "Codex")
                provider.sendAction(provider.action, to: provider.target)
            }
            check("Provider is stored", Settings.maestroAgent() == .codex)
            if let model = find(NSComboBox.self) {
                check("Model offers the provider's models", model.objectValues as? [String] == ["gpt-5.5"])
                model.stringValue = "gpt-5.5"
                model.sendAction(model.action, to: model.target)
            }
            check("Model is stored for the provider",
                  Settings.maestroModel(.codex) == "gpt-5.5" && Settings.maestroModel(.claude) == "")
            if let editor {
                let end = NSRange(location: (editor.string as NSString).length, length: 0)
                editor.insertText("\n## Demo\n\nHand test runs to a Codex worker.\n", replacementRange: end)
                editor.scrollToEndOfDocument(nil)
            }
            check("Save is on after an edit", button("Save")?.isEnabled == true)
            check("the file is not written before Save",
                  home.flatMap(ManagerHome.readContext(home:))?.contains("## Demo") == false)
            shot("2-maestro-edited.png")
            button("Save")?.performClick(nil)
            next(after: 0.3)
        }

        private func saved() {
            let text = home.flatMap(ManagerHome.readContext(home:)) ?? ""
            check("Save writes CLAUDE.md", text.hasSuffix("Hand test runs to a Codex worker.\n"))
            let agents = home.flatMap { try? String(contentsOf: $0.appendingPathComponent("AGENTS.md"), encoding: .utf8) }
            check("AGENTS.md reads the same", agents == text && !text.isEmpty)
            check("Save is off again", button("Save")?.isEnabled == false)
            shot("3-maestro-saved.png")
            next(after: 0.2)
        }

        private func restart() {
            check("Restart Maestro is there", button("Restart Maestro") != nil)
            button("Restart Maestro")?.performClick(nil)
            // The script reads the pane the restart made.
            next(after: 4)
        }

        private func phone() {
            selectTab("Phone")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.check("Phone tab", self.window?.title == "Phone" && self.find(PhoneSettingsView.self) != nil)
                let folder = self.window?.contentView.flatMap(self.all)?
                    .first { $0 is NSTextField && $0.accessibilityLabel() == "Upload folder" } as? NSTextField
                self.check("Upload folder starts as the temp folder",
                           folder?.stringValue == MobileReply.defaultUploadFolder, folder?.stringValue ?? "no field")
                if let folder {
                    folder.stringValue = "~/Screenshots"
                    folder.sendAction(folder.action, to: folder.target)
                }
                self.check("Upload folder is stored",
                           Settings.phoneUploadFolder() == NSHomeDirectory() + "/Screenshots"
                               && folder?.stringValue == "~/Screenshots", Settings.phoneUploadFolder())
                let folders = self.window?.contentView.flatMap(self.all)?
                    .first { $0 is NSTextField && $0.accessibilityLabel() == "Artifact folders" } as? NSTextField
                if let folders {
                    folders.stringValue = "~/reports, not a path"
                    folders.sendAction(folders.action, to: folders.target)
                }
                self.check("Artifact folders are stored",
                           Settings.phoneArtifactFolders() == [NSHomeDirectory() + "/reports"]
                               && folders?.stringValue == "~/reports",
                           folders?.stringValue ?? "no field")
                self.shot("4-phone.png")
                self.next(after: 0.2)
            }
        }

        private func tools() {
            selectTab("Tools")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.check("Tools tab", self.window?.title == "Tools" && self.button("Check Again") != nil)
                self.shot("5-tools.png")
                self.next(after: 0.2)
            }
        }

        private func finish() {
            lines.append(ok ? "SETTINGS SELFTEST PASSED" : "SETTINGS SELFTEST FAILED")
            print(lines.joined(separator: "\n"))
            exit(ok ? 0 : 1)
        }
    }
}
