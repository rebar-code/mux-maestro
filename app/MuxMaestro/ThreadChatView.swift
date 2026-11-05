import Cocoa

/// The selected pane's agent as a chat, in the terminal's place: the view the
/// Maestro rail uses, fed from the pane's own transcript. A send is the
/// phone's reply: a checked paste and then Enter, refused while the pane
/// waits on a prompt. A busy agent queues the text until its turn ends.
final class ThreadChatView: NSView {
    /// The pane the chat follows, and the agent sessions that name its
    /// transcript.
    struct Target: Equatable {
        let host: Host
        let pane: String
        let claudeSessionId: String?
        let codexSessionId: String?
    }

    private let chat = ChatTranscriptView()
    private let composer = ChatComposer()
    private let state = PaneStateBox()
    private var sending = false

    private(set) var target: Target?

    /// The target's transcript. Blocking; called off the main thread.
    var transcript: ((Target) -> (path: String, codex: Bool)?)?
    /// What may be done to the target's pane. Called on the main thread; its
    /// closures block.
    var paneIO: ((Target) -> MobilePaneIO)?

    var onOpenLink: ((ThreadLink) -> Void)? {
        get { chat.onOpenLink }
        set { chat.onOpenLink = newValue }
    }

    /// The pane waits on something with no readable choices.
    var onShowTerminal: (() -> Void)? {
        get { chat.onShowTerminal }
        set { chat.onShowTerminal = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = SidebarPalette.bg.cgColor
        chat.translatesAutoresizingMaskIntoConstraints = false
        chat.emptyText = Self.noAgent
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.placeholder = "Message"
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.isHidden = true
        addSubview(chat)
        addSubview(composer)
        // A readable column, like the phone's, centred in a wide pane.
        let wide = chat.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            chat.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            chat.centerXAnchor.constraint(equalTo: centerXAnchor),
            chat.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            chat.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            wide,
            chat.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: chat.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: chat.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static let noAgent = "No agent in this pane"

    /// Follow the selected pane. A pane with no Claude or Codex session has no
    /// chat. Called on each tree refresh: only a new target starts over.
    func follow(_ pane: TmuxPane?, host: Host?) {
        guard let pane, let host, pane.claudeSessionId != nil || pane.codexSessionId != nil else {
            setTarget(nil)
            return
        }
        state.value = MobilePaneState(
            status: pane.attention, since: pane.agentState?.since, remote: !host.isLocal)
        setTarget(Target(
            host: host, pane: pane.id, claudeSessionId: pane.claudeSessionId,
            codexSessionId: pane.codexSessionId))
    }

    func focus() {
        composer.focus()
    }

    private func setTarget(_ new: Target?) {
        guard new != target else { return }
        target = new
        if new == nil { state.value = nil }
        composer.isHidden = new == nil
        chat.emptyText = new == nil ? Self.noAgent : nil
        chat.source = new.flatMap(source(for:))
    }

    private func source(for target: Target) -> ChatSource? {
        guard let transcript, let paneIO else { return nil }
        let state = state
        let io = paneIO(target)
        return ChatSource(
            transcript: { transcript(target) },
            pane: { ChatPane(target: target.pane, io: io, state: { state.value }) })
    }

    private func send(_ text: String) {
        guard let target, let paneIO, !sending else {
            composer.text = text
            return
        }
        // Pasted into a terminal: a control character there is a key press.
        guard text.utf8.count <= MobileManager.maxTextBytes,
              text.unicodeScalars.allSatisfy(MobileManager.isText)
        else {
            composer.text = text
            chat.addNote("Not sent: too long, or it holds a control key")
            return
        }
        sending = true
        chat.addPending(text)
        let io = paneIO(target)
        let state = state
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response = MobileReply.send(
                text, queue: true, target: target.pane, io: io, state: { state.value })
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                if response.status == 200 {
                    self.chat.refreshSoon()
                } else {
                    self.chat.dropPending(text)
                    self.chat.addNote(ChatTranscriptView.message(of: response))
                    if self.composer.text.isEmpty { self.composer.text = text }
                }
            }
        }
    }
}

/// The pane's state as the last tree read it, for the reads and the send that
/// run off the main thread.
private final class PaneStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MobilePaneState?

    var value: MobilePaneState? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
