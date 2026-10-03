import Cocoa

/// An NSTextField that also accepts a dropped file/folder from Finder (or the
/// sidebar), filling itself with the dropped item's path. Paste (⌘V) already
/// works on any text field, so this adds the drag-and-drop half.
final class PathDropTextField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL
        else { return false }
        stringValue = url.path
        return true
    }
}

/// A simple single-line text prompt presented as a modal alert with a text
/// field. Returns the trimmed entered text, or nil if cancelled / empty.
enum TextPrompt {
    static func run(
        window: NSWindow?, title: String, message: String, defaultValue: String,
        allowsFileDrop: Bool = false
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let field = allowsFileDrop ? PathDropTextField(frame: frame) : NSTextField(frame: frame)
        field.stringValue = defaultValue
        field.placeholderString = allowsFileDrop ? "path (or drop a file)" : "name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// New-session prompt: a native directory picker plus an optional name and a
/// "launch claude" toggle. Returns (name, dir, launchClaude) or nil if
/// cancelled. The name defaults to the chosen directory's last path component.
enum NewSessionPrompt {
    static func run(window: NSWindow?, defaultDir: String) -> (name: String, dir: String, launchClaude: Bool)? {
        // 1. Pick the directory.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a working directory for the new session"
        panel.directoryURL = URL(fileURLWithPath: defaultDir)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let dir = url.path

        // 2. Name + launch toggle via an alert with an accessory view.
        let alert = NSAlert()
        alert.messageText = "New Session"
        alert.informativeText = "in \(dir)"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        nameField.stringValue = url.lastPathComponent
        nameField.placeholderString = "session name"
        accessory.addSubview(nameField)

        let claudeToggle = NSButton(
            checkboxWithTitle: "Launch claude in this session", target: nil, action: nil)
        claudeToggle.frame = NSRect(x: 0, y: 2, width: 300, height: 20)
        claudeToggle.state = .off
        accessory.addSubview(claudeToggle)

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? url.lastPathComponent : name
        return (name: finalName, dir: dir, launchClaude: claudeToggle.state == .on)
    }

    /// Quick local variant (the ⌘N path): one alert, no file picker. The session
    /// starts in `defaultDir` (home) — there's no directory field; `cd` inside the
    /// session afterwards. The name is pre-filled, so hitting Enter creates it
    /// immediately; type over the name to override.
    static func runQuick(
        window: NSWindow?, defaultName: String, defaultDir: String
    ) -> (name: String, dir: String, launchClaude: Bool)? {
        let alert = NSAlert()
        alert.messageText = "New Session"
        alert.informativeText = "Name it (or press Enter for the default)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        nameField.stringValue = defaultName
        nameField.placeholderString = "session name"
        accessory.addSubview(nameField)

        let claudeToggle = NSButton(
            checkboxWithTitle: "Launch claude in this session", target: nil, action: nil)
        claudeToggle.frame = NSRect(x: 0, y: 2, width: 320, height: 20)
        claudeToggle.state = .off
        accessory.addSubview(claudeToggle)

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField
        // Select the pre-filled name so the user can type over it immediately.
        nameField.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            name: name.isEmpty ? defaultName : name,
            dir: defaultDir,
            launchClaude: claudeToggle.state == .on)
    }

    /// Remote variant: name + launch-claude toggle only. The session starts in the
    /// remote home (`~`); `cd` inside it afterwards.
    static func runRemote(
        window: NSWindow?, host: String, defaultDir: String
    ) -> (name: String, dir: String, launchClaude: Bool)? {
        let alert = NSAlert()
        alert.messageText = "New Session on \(host)"
        alert.informativeText = "Name it. The session starts in your home directory."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        nameField.placeholderString = "session name"
        accessory.addSubview(nameField)

        let claudeToggle = NSButton(
            checkboxWithTitle: "Launch claude in this session", target: nil, action: nil)
        claudeToggle.frame = NSRect(x: 0, y: 2, width: 320, height: 20)
        claudeToggle.state = .off
        accessory.addSubview(claudeToggle)

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // No directory last-component to fall back to remotely; require a name.
        guard !name.isEmpty else { return nil }
        return (name: name, dir: "~", launchClaude: claudeToggle.state == .on)
    }
}

/// Recover Previous Sessions picker: one checkbox per lost Claude Code session
/// (all pre-checked — the common case is "give me last night back"), plus a
/// toggle between starting `claude --resume` immediately and just typing it in
/// each pane. Returns the chosen sessions, or nil if cancelled / none checked.
enum RecoverSessionsPrompt {
    /// Document view that lays out top-down so the first (most recent) session
    /// is at the top of the scroll area, not the bottom.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    static func run(
        window: NSWindow?, candidates: [RecoverableSession]
    ) -> (sessions: [RecoverableSession], autostart: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Recover Previous Sessions"
        alert.informativeText = "These Claude Code sessions were live when tmux last "
            + "shut down. Each one recovers into its own tmux session, resumed with "
            + "claude --resume."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 440
        let rowHeight: CGFloat = 22
        let listHeight = min(CGFloat(candidates.count) * rowHeight, 264)

        let doc = FlippedView(frame: NSRect(
            x: 0, y: 0, width: width - 16, height: CGFloat(candidates.count) * rowHeight))
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .abbreviated
        let home = NSHomeDirectory()
        let checks: [NSButton] = candidates.enumerated().map { i, c in
            var dir = c.cwd
            if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
            var title = "\(c.suggestedSessionName)  —  \(dir)  ·  "
                + ago.localizedString(for: c.lastActive, relativeTo: Date())
            if c.hasNewerActivity { title += "  ·  newer work exists" }
            let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            check.state = .on
            check.frame = NSRect(
                x: 0, y: CGFloat(i) * rowHeight, width: width - 16, height: rowHeight)
            check.lineBreakMode = .byTruncatingMiddle
            doc.addSubview(check)
            return check
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 32, width: width, height: listHeight))
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = candidates.count > 12 ? .automatic : .none

        let autostartToggle = NSButton(
            checkboxWithTitle: "Start claude immediately (unchecked: the resume command "
                + "is typed, press Enter in each pane)",
            target: nil, action: nil)
        autostartToggle.frame = NSRect(x: 0, y: 4, width: width, height: 20)
        autostartToggle.state = .on

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: listHeight + 36))
        accessory.addSubview(scroll)
        accessory.addSubview(autostartToggle)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let chosen = zip(candidates, checks).filter { $0.1.state == .on }.map(\.0)
        guard !chosen.isEmpty else { return nil }
        return (sessions: chosen, autostart: autostartToggle.state == .on)
    }
}

/// Add Server sheet (M10): captures Name/HostName/User/Port and an auth method
/// (1Password agent + Touch ID / key file / default agent). For the key-file and
/// 1Password-public-key cases it offers a native file picker — but only the
/// chosen PATH is ever stored, never the key contents. Returns a `ServerEntry`
/// or nil if cancelled. Validation (non-empty name) keeps the alert up.
enum AddServerPrompt {
    /// Auth method indices in the popup, mirrored by `authMethod(...)`.
    private enum AuthChoice: Int { case onePassword = 0, keyFile = 1, defaultAgent = 2 }

    /// What the sheet captures: the ssh-config entry plus the two app-level
    /// connection prefs (mosh / watch), which are NOT ssh directives so they're
    /// returned separately and written to `Settings` by the caller after save.
    struct Result {
        let entry: ServerEntry
        let useMosh: Bool
        let watch: Bool
    }

    /// `editing` prefills the sheet from an existing entry (Edit Server…);
    /// `useMosh`/`watch` seed the toggles from the host's current settings. When
    /// nil the sheet is the plain Add flow.
    static func run(
        window: NSWindow?, editing: ServerEntry? = nil,
        useMosh: Bool = false, watch: Bool = true
    ) -> Result? {
        let alert = NSAlert()
        alert.messageText = editing == nil ? "Add Server" : "Edit Server"
        let secretsNote = "Only host metadata and a key path or agent reference are "
            + "saved — never a private key or secret."
        alert.informativeText = editing == nil
            ? "Adds to your SSH config: the host is written to ~/.ssh/sidekick_hosts, "
                + "which ~/.ssh/config Includes (added once, after backing it up). "
                + secretsNote
            : "Updates this host in ~/.ssh/sidekick_hosts (Included from "
                + "~/.ssh/config). " + secretsNote
        alert.addButton(withTitle: editing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 360
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 268))

        func label(_ s: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.frame = NSRect(x: 0, y: y, width: 100, height: 20)
            l.alignment = .right
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            return l
        }
        func field(_ placeholder: String, y: CGFloat, value: String = "") -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 108, y: y, width: width - 108, height: 22))
            f.placeholderString = placeholder
            f.stringValue = value
            return f
        }

        let nameField = field("alias (ssh <name>)", y: 240, value: editing?.name ?? "")
        let hostField = field("hostname or IP", y: 212, value: editing?.hostName ?? "")
        let userField = field("user", y: 184, value: editing?.user ?? "")
        let portField = field("22", y: 156, value: String(editing?.port ?? 22))

        let authPopup = NSPopUpButton(
            frame: NSRect(x: 108, y: 124, width: width - 108, height: 24), pullsDown: false)
        authPopup.addItems(withTitles: [
            "1Password agent (Touch ID)", "Key file", "Default agent",
        ])
        // Seed the popup + key field from the entry being edited, mirroring how
        // `authMethod` reads them back out below.
        if let auth = editing?.auth {
            switch auth {
            case .onePasswordAgent: authPopup.selectItem(at: AuthChoice.onePassword.rawValue)
            case .keyFile: authPopup.selectItem(at: AuthChoice.keyFile.rawValue)
            case .defaultAgent: authPopup.selectItem(at: AuthChoice.defaultAgent.rawValue)
            }
        }

        // Optional key/public-key path + Browse button (shown for both key modes).
        let existingKeyPath: String = {
            switch editing?.auth {
            case .onePasswordAgent(let pub): return pub ?? ""
            case .keyFile(let path): return path
            default: return ""
            }
        }()
        let keyField = field(
            "identity / public key path (optional for 1Password)", y: 88,
            value: existingKeyPath)
        keyField.frame.size.width = width - 108 - 76
        let browse = NSButton(
            frame: NSRect(x: width - 72, y: 86, width: 72, height: 26))
        browse.title = "Browse…"
        browse.bezelStyle = .rounded

        // Browse uses an NSOpenPanel; only the PATH is captured.
        let browseHandler = BrowseHandler(field: keyField)
        browse.target = browseHandler
        browse.action = #selector(BrowseHandler.browse)

        // App-level connection prefs (not ssh directives). Watch defaults on so a
        // newly-added server is live in the sidebar immediately; mosh is opt-in.
        let watchToggle = NSButton(
            checkboxWithTitle: "Watch this server (keep it polled while collapsed)",
            target: nil, action: nil)
        watchToggle.frame = NSRect(x: 108, y: 44, width: width - 108, height: 20)
        watchToggle.state = watch ? .on : .off
        let moshToggle = NSButton(
            checkboxWithTitle: "Use mosh for terminal (roaming, survives network changes)",
            target: nil, action: nil)
        moshToggle.frame = NSRect(x: 108, y: 18, width: width - 108, height: 20)
        moshToggle.state = useMosh ? .on : .off

        for v in [
            label("Name", y: 240), nameField,
            label("HostName", y: 212), hostField,
            label("User", y: 184), userField,
            label("Port", y: 156), portField,
            label("Auth", y: 124), authPopup,
            label("Key path", y: 88), keyField, browse,
            watchToggle, moshToggle,
        ] { accessory.addSubview(v) }

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        // Loop rather than returning on the first invalid submission: a bad key
        // path (the exact bug this check exists for — a directory like `~/.ssh`
        // accepted in place of the key file inside it) should re-open the same
        // sheet with the fields intact, not silently fail deep in a later ssh
        // probe with an opaque "Is a directory" error.
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            _ = browseHandler  // keep the handler alive until the modal closes.

            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let keyPath = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let auth: SshAuthMethod
            switch AuthChoice(rawValue: authPopup.indexOfSelectedItem) ?? .onePassword {
            case .onePassword:
                auth = .onePasswordAgent(publicKeyPath: keyPath.isEmpty ? nil : keyPath)
            case .keyFile:
                auth = .keyFile(path: keyPath)
            case .defaultAgent:
                auth = .defaultAgent
            }

            if let reason = AddServer.invalidKeyPathReason(for: auth) {
                let err = NSAlert()
                err.messageText = "Invalid key path"
                err.informativeText = reason
                err.alertStyle = .warning
                err.runModal()
                continue
            }

            let entry = ServerEntry(
                name: name,
                hostName: hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                user: userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22,
                auth: auth)
            return Result(
                entry: entry, useMosh: moshToggle.state == .on, watch: watchToggle.state == .on)
        }
    }

    /// Target for the Browse button (NSButton needs an ObjC target). Captures
    /// only the chosen file PATH into the key field — never the file contents.
    final class BrowseHandler: NSObject {
        let field: NSTextField
        init(field: NSTextField) { self.field = field }

        @objc func browse() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Choose the key file (only its path is stored)"
            panel.directoryURL = URL(
                fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
            panel.showsHiddenFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                field.stringValue = url.path
            }
        }
    }
}
