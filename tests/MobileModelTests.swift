import XCTest

/// The `/model` menus as tmux captures them (Claude Code v2.1.295, Codex
/// v0.162.0), with demo names.
enum DemoModelMenu {
    static let claudeTop = """
         ▐▛███▛█   Claude Code v2.1.295
        ▝▜██████▀  Opus 5.5 with high effort · Claude Max
         ▝▝   ▝▝   /Users/me/acme-app

        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
           Select model
           Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model
           names, specify with --model.

             1.  Default (recommended)  Sonnet 5.5 · Efficient for routine tasks
           ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks
             3.  Fable 5.1              For your toughest challenges
             4.  Sonnet 5.5             Most efficient for simpler tasks
             5.  Haiku 5.5              Fastest for quick answers
             6.  Haiku 4.5              Fastest for quick answers
             7.  Sonnet 5               Efficient for routine tasks
             8.  Opus 5                 Best for everyday, complex tasks
             9.  Fable 5                Most capable for your hardest and longest-running tasks
           ↓ 10. Opus 4.8               Best for everyday, complex tasks
              … +3 models

           ● High effort ←/→ to adjust

           Enter to set as default · s to use this session only · Esc to cancel
        """

    static let claudeBottom = """
           Select model
           Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model
           names, specify with --model.

           ↑ 4.  Sonnet 5.5             Most efficient for simpler tasks
             5.  Haiku 5.5              Fastest for quick answers
             6.  Haiku 4.5              Fastest for quick answers
             7.  Sonnet 5               Efficient for routine tasks
             8.  Opus 5                 Best for everyday, complex tasks
             9.  Fable 5                Most capable for your hardest and longest-running tasks
             10. Opus 4.8               Best for everyday, complex tasks
             11. Opus 4.7               Best for everyday, complex tasks
             12. Opus 4.6               Best for everyday, complex tasks
           ❯ 13. Sonnet 4.6             Efficient for routine tasks

           ● High effort (default) ←/→ to adjust

           Enter to set as default · s to use this session only · Esc to cancel
        """

    static let claudeNoEffort = """
           Select model

             5.  Haiku 5.5              Fastest for quick answers
           ❯ 6.  Haiku 4.5              Fastest for quick answers
             7.  Sonnet 5               Efficient for routine tasks

           ○ Effort not supported for Haiku 4.5

           Enter to set as default · s to use this session only · Esc to cancel
        """

    /// The menu is closed: what it said is in the scrollback, over the input box.
    static let claudeClosed = """
        ❯ /model
          ⎿  Kept model as Opus 5.5

        ────────────────────────────────────────
        ❯
        ────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """

    static let codexModels = """
          >_ OpenAI Codex (v0.162.0)
             /Users/me/acme-app

          Select Model and Effort

          1. GPT-6.1-Sol           Latest workhorse model for coding and everyday work.
          2. GPT-6-Astra           Frontier intelligence for the most demanding work.
          3. GPT-6-Sol             Previous generation workhorse model.
        › 4. GPT-6-Luna (current)  Fast and affordable model for easier tasks.
          5. GPT-5.6-Sol           Older generation workhorse model.

          enter select · esc back
        """

    static let codexEfforts = """
          Select Reasoning Level for GPT-6-Luna

          1. Low                         Fast responses with lighter reasoning
        › 2. Medium (default) (current)  Balances speed and reasoning depth for everyday tasks
          3. High                        Greater reasoning depth for complex problems
          4. Extra high                  Extra high reasoning depth for complex problems
          5. More reasoning…             Max consumes usage limits faster

          enter default · s session · esc back
        """
}

/// An agent's `/model` menu, scripted: it takes the keys the two agents take
/// and draws what they draw.
final class FakeModelMenu {
    struct Model {
        let label: String
        var levels: [String] = ["Low", "Medium", "High", "xHigh", "Max"]
        var normal = "High"
    }

    let agent: MobileModelMenu.Agent
    var models: [Model]
    /// The menu offers `s` for "this session only".
    var sessionKey = true
    private(set) var isOpen = false
    private(set) var cursor = 0
    private(set) var level = 0
    private var top = 0
    /// Codex: the list of levels is in front.
    private var onLevels = false
    /// The model and level in use.
    private(set) var current: (model: Int, level: String)
    /// What `s` took, for this session.
    private(set) var applied: (model: String, effort: String?)?
    /// Enter took a pick: it is now the default for every new session.
    private(set) var saved = false

    static let window = 10

    init(agent: MobileModelMenu.Agent, models: [Model], current: Int) {
        self.agent = agent
        self.models = models
        self.current = (current, models[current].normal)
    }

    static func claude() -> FakeModelMenu {
        let names = [
            "Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 5.5", "Haiku 4.5", "Sonnet 5",
            "Opus 5", "Fable 5", "Opus 4.8", "Opus 4.7", "Opus 4.6", "Sonnet 4.6",
        ]
        var models = names.map { Model(label: $0) }
        models[5].levels = []
        models[4].normal = "Medium"
        return FakeModelMenu(agent: .claude, models: models, current: 1)
    }

    static func codex() -> FakeModelMenu {
        let names = ["GPT-6.1-Sol", "GPT-6-Astra", "GPT-6-Sol", "GPT-6-Luna", "GPT-5.6-Sol"]
        let levels = ["Low", "Medium", "High", "Extra high"]
        return FakeModelMenu(
            agent: .codex, models: names.map { Model(label: $0, levels: levels, normal: "Medium") }, current: 3)
    }

    private func place() {
        let model = models[cursor]
        let now = cursor == current.model ? current.level : model.normal
        level = model.levels.firstIndex(of: now) ?? 0
        top = min(max(top, cursor - Self.window + 1), cursor)
    }

    func open() {
        isOpen = true
        onLevels = false
        cursor = current.model
        top = 0
        place()
    }

    private func take(save: Bool) {
        let model = models[cursor]
        applied = (model.label, model.levels.isEmpty ? nil : model.levels[level])
        current = (cursor, model.levels.isEmpty ? "" : model.levels[level])
        saved = saved || save
        isOpen = false
    }

    func press(_ key: String) {
        guard isOpen else { return }
        let count = onLevels ? models[cursor].levels.count + 1 : models.count
        switch key {
        case "Up", "Down":
            let step = key == "Up" ? count - 1 : 1
            if onLevels {
                level = (level + step) % count
            } else {
                cursor = (cursor + step) % count
                place()
            }
        case "Left" where agent == .claude: level = max(level - 1, 0)
        case "Right" where agent == .claude: level = min(level + 1, max(models[cursor].levels.count - 1, 0))
        case "Escape":
            if onLevels { onLevels = false } else { isOpen = false }
        case "Enter":
            if agent == .codex, !onLevels {
                onLevels = true
            } else if !onLevels || level < models[cursor].levels.count {
                take(save: true)
            }
        case "s" where sessionKey && (agent == .claude || onLevels):
            if !onLevels || level < models[cursor].levels.count { take(save: false) }
        default: break
        }
    }

    var screen: String {
        guard isOpen else { return DemoPrompt.idle }
        return agent == .claude ? claudeScreen : codexScreen
    }

    private var claudeScreen: String {
        let shown = top..<min(top + Self.window, models.count)
        var lines = ["   Select model", "   Switch between Claude models.", ""]
        for index in shown {
            var mark = index == cursor ? "❯" : " "
            if index == shown.lowerBound, top > 0 { mark = index == cursor ? "❯ ↑" : "↑" }
            if index == shown.upperBound - 1, shown.upperBound < models.count { mark = "↓" }
            let label = models[index].label + (index == current.model ? " ✔" : "")
            lines.append("   \(mark) \(index + 1). \(label.padding(toLength: 24, withPad: " ", startingAt: 0))  About it")
        }
        if shown.upperBound < models.count { lines.append("      … +\(models.count - shown.upperBound) models") }
        let model = models[cursor]
        let normal = !model.levels.isEmpty && model.levels[level] == model.normal ? " (default)" : ""
        lines += [
            "",
            model.levels.isEmpty
                ? "   ○ Effort not supported for \(model.label)"
                : "   ● \(model.levels[level]) effort\(normal) ←/→ to adjust",
            "",
            "   Enter to set as default" + (sessionKey ? " · s to use this session only" : "") + " · Esc to cancel",
        ]
        return lines.joined(separator: "\n")
    }

    private var codexScreen: String {
        var lines: [String]
        if onLevels {
            let model = models[cursor]
            lines = ["  Select Reasoning Level for \(model.label)", ""]
            for (index, name) in (model.levels + ["More reasoning…"]).enumerated() {
                var label = name
                if name == model.normal { label += " (default)" }
                if cursor == current.model, name == current.level { label += " (current)" }
                lines.append("\(index == level ? "›" : " ") \(index + 1). \(label)   About it")
            }
            lines += ["", "  enter default" + (sessionKey ? " · s session" : "") + " · esc back"]
        } else {
            lines = ["  Select Model and Effort", ""]
            for (index, model) in models.enumerated() {
                let label = model.label + (index == current.model ? " (current)" : "")
                lines.append("\(index == cursor ? "›" : " ") \(index + 1). \(label)   About it")
            }
            lines += ["", "  enter select · esc back"]
        }
        return lines.joined(separator: "\n")
    }
}

final class MobileModelTests: XCTestCase {
    private let target = "%12"

    private func state(_ status: AttentionStatus = .idle) -> MobilePaneState {
        MobilePaneState(status: status, since: nil)
    }

    /// A pane whose agent shows `menu` once `/model` is sent.
    private func pane(_ menu: FakeModelMenu) -> FakePane {
        let pane = FakePane()
        pane.screenAfterPaste = DemoPrompt.input(MobileModel.command)
        pane.onKeys = { args in
            let keys = args.dropFirst(3)
            if !menu.isOpen, keys == ["Enter"] {
                menu.open()
            } else {
                keys.forEach(menu.press)
            }
            pane.screenAfterPaste = nil
            pane.screen = menu.screen
        }
        return pane
    }

    private func run(
        _ request: MobileModel.Request, _ pane: FakePane, status: AttentionStatus = .idle
    ) -> (status: Int, body: [String: Any]) {
        let response = MobileModel.run(
            request, target: target, io: pane.io, state: { self.state(status) }, pause: { _ in })
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return (response.status, body ?? [:])
    }

    private func labels(_ body: [String: Any], _ key: String) -> [String] {
        (body[key] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
    }

    private func current(_ body: [String: Any], _ key: String) -> [String] {
        (body[key] as? [[String: Any]] ?? []).filter { $0["current"] as? Bool == true }
            .compactMap { $0["label"] as? String }
    }

    /// The keys pressed, without the calls that paste.
    private func keys(_ pane: FakePane) -> [String] {
        pane.argv.filter { $0.first == "send-keys" }.flatMap { $0.dropFirst(3) }
    }

    // MARK: the screen

    func testReadsClaudeCodesMenu() throws {
        let menu = try XCTUnwrap(MobileModelMenu(DemoModelMenu.claudeTop))
        XCTAssertEqual(menu.agent, .claude)
        XCTAssertEqual(menu.step, .model)
        XCTAssertEqual(menu.rows.map(\.n), Array(1...10))
        XCTAssertEqual(menu.rows[0].label, "Default (recommended)")
        XCTAssertEqual(menu.rows[0].description, "Sonnet 5.5 · Efficient for routine tasks")
        XCTAssertEqual(menu.selected?.label, "Opus 5.5")
        XCTAssertEqual(menu.rows.filter(\.current).map(\.label), ["Opus 5.5"])
        XCTAssertEqual(menu.rows[9].label, "Opus 4.8")
        XCTAssertFalse(menu.moreAbove)
        XCTAssertTrue(menu.moreBelow)
        XCTAssertEqual(menu.effort, .level("High"))
        XCTAssertTrue(menu.sessionKey)
        XCTAssertFalse(menu.advances)
    }

    func testReadsAScrolledMenuAndAModelWithoutEffort() throws {
        let bottom = try XCTUnwrap(MobileModelMenu(DemoModelMenu.claudeBottom))
        XCTAssertEqual(bottom.rows.map(\.n), Array(4...13))
        XCTAssertTrue(bottom.moreAbove)
        XCTAssertFalse(bottom.moreBelow)
        XCTAssertEqual(bottom.selected?.label, "Sonnet 4.6")
        XCTAssertEqual(bottom.effort, .level("High"))

        let plain = try XCTUnwrap(MobileModelMenu(DemoModelMenu.claudeNoEffort))
        XCTAssertEqual(plain.effort, .unsupported)
        XCTAssertEqual(plain.selected?.label, "Haiku 4.5")
    }

    func testReadsCodexsTwoLists() throws {
        let models = try XCTUnwrap(MobileModelMenu(DemoModelMenu.codexModels))
        XCTAssertEqual(models.agent, .codex)
        XCTAssertEqual(models.step, .model)
        XCTAssertEqual(models.selected?.label, "GPT-6-Luna")
        XCTAssertEqual(models.rows.filter(\.current).map(\.label), ["GPT-6-Luna"])
        XCTAssertTrue(models.advances)
        // Enter opens the next list here; nothing is taken yet.
        XCTAssertFalse(models.sessionKey)
        XCTAssertNil(models.effort)

        let levels = try XCTUnwrap(MobileModelMenu(DemoModelMenu.codexEfforts))
        XCTAssertEqual(levels.step, .effort)
        XCTAssertEqual(levels.subject, "GPT-6-Luna")
        XCTAssertEqual(levels.rows.map(\.label), ["Low", "Medium", "High", "Extra high", "More reasoning…"])
        XCTAssertEqual(levels.rows.filter(\.opens).map(\.label), ["More reasoning…"])
        XCTAssertEqual(levels.rows.filter(\.current).map(\.label), ["Medium"])
        XCTAssertTrue(levels.sessionKey)
        XCTAssertFalse(levels.advances)
    }

    func testAScreenWithoutTheMenuInFrontIsNoMenu() {
        XCTAssertNil(MobileModelMenu(DemoModelMenu.claudeClosed))
        XCTAssertNil(MobileModelMenu(DemoPrompt.idle))
        XCTAssertNil(MobileModelMenu(DemoPrompt.codexTrust))
        // The menu in the scrollback, with the input box under it.
        XCTAssertNil(MobileModelMenu(DemoModelMenu.codexModels + "\n\n" + DemoPrompt.idle))
        XCTAssertNil(MobileModelMenu(""))
    }

    // MARK: the request

    func testReadsTheRequest() {
        let ask = { (json: String) in MobileModel.request(in: Data(json.utf8)) }
        XCTAssertEqual(ask(#"{"step":"open"}"#), .open)
        XCTAssertEqual(ask(#"{"step":"cancel"}"#), .cancel)
        XCTAssertEqual(ask(#"{"step":"model","n":5,"label":"Haiku 5.5"}"#), .model(n: 5, label: "Haiku 5.5"))
        XCTAssertEqual(
            ask(#"{"step":"apply","model":"Haiku 5.5","effort":"Low"}"#), .apply(model: "Haiku 5.5", effort: "Low"))
        XCTAssertEqual(ask(#"{"step":"apply","model":"Haiku 4.5"}"#), .apply(model: "Haiku 4.5", effort: nil))
        XCTAssertEqual(
            ask(#"{"step":"apply","model":"Haiku 4.5","effort":null}"#), .apply(model: "Haiku 4.5", effort: nil))
        for bad in [
            "", "{}", #"{"step":"save"}"#, #"{"step":"model","n":true,"label":"x"}"#,
            #"{"step":"model","n":0,"label":"x"}"#, #"{"step":"model","n":1.5,"label":"x"}"#,
            #"{"step":"model","n":1}"#, #"{"step":"apply"}"#, #"{"step":"apply","model":"x","effort":3}"#,
            #"{"step":"apply","model":""}"#,
        ] {
            XCTAssertNil(ask(bad), bad)
        }
    }

    // MARK: Claude Code

    func testOpensClaudeCodesMenuAndListsEveryModel() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        let opened = run(.open, pane)
        XCTAssertEqual(opened.status, 200)
        XCTAssertEqual(opened.body["agent"] as? String, "claude")
        // Thirteen models, on a list that shows ten.
        XCTAssertEqual(labels(opened.body, "models"), menu.models.map(\.label))
        XCTAssertEqual(current(opened.body, "models"), ["Opus 5.5"])
        // `/model` went in as a reply does: one paste, then Enter.
        XCTAssertEqual(pane.calls.first { $0.args.first == "load-buffer" }?.stdin, "/model")
        XCTAssertTrue(menu.isOpen)
        XCTAssertFalse(menu.saved)
    }

    func testTakesAClaudeModelAndEffortForThisSessionOnly() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)

        let picked = run(.model(n: 5, label: "Haiku 5.5"), pane)
        XCTAssertEqual(picked.status, 200)
        XCTAssertEqual(labels(picked.body, "efforts"), ["Low", "Medium", "High", "xHigh", "Max"])
        XCTAssertEqual(current(picked.body, "efforts"), ["Medium"])
        XCTAssertEqual(menu.cursor, 4)

        let applied = run(.apply(model: "Haiku 5.5", effort: "xHigh"), pane)
        XCTAssertEqual(applied.status, 200)
        XCTAssertEqual(menu.applied?.model, "Haiku 5.5")
        XCTAssertEqual(menu.applied?.effort, "xHigh")
        XCTAssertFalse(menu.isOpen)
        // Enter in the menu would make the pick the default for new sessions.
        XCTAssertFalse(menu.saved)
        XCTAssertEqual(keys(pane).filter { $0 == "Enter" }.count, 1)
        XCTAssertEqual(keys(pane).last, "s")
    }

    func testAClaudeModelWithoutEffortHasNoLevels() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        let picked = run(.model(n: 6, label: "Haiku 4.5"), pane)
        XCTAssertEqual(picked.status, 200)
        XCTAssertEqual(labels(picked.body, "efforts"), [])
        XCTAssertEqual(run(.apply(model: "Haiku 4.5", effort: nil), pane).status, 200)
        XCTAssertEqual(menu.applied?.model, "Haiku 4.5")
        XCTAssertNil(menu.applied?.effort)
        XCTAssertFalse(menu.saved)
    }

    // MARK: Codex

    func testTakesACodexModelAndLevelForThisSessionOnly() {
        let menu = FakeModelMenu.codex()
        let pane = pane(menu)
        let opened = run(.open, pane)
        XCTAssertEqual(opened.body["agent"] as? String, "codex")
        XCTAssertEqual(labels(opened.body, "models"), menu.models.map(\.label))
        XCTAssertEqual(current(opened.body, "models"), ["GPT-6-Luna"])

        let picked = run(.model(n: 2, label: "GPT-6-Astra"), pane)
        XCTAssertEqual(picked.status, 200)
        // `More reasoning…` opens another menu and is not offered.
        XCTAssertEqual(labels(picked.body, "efforts"), ["Low", "Medium", "High", "Extra high"])
        // Not the session's model: the level the list starts on is marked.
        XCTAssertEqual(current(picked.body, "efforts"), ["Medium"])

        XCTAssertEqual(run(.apply(model: "GPT-6-Astra", effort: "High"), pane).status, 200)
        XCTAssertEqual(menu.applied?.model, "GPT-6-Astra")
        XCTAssertEqual(menu.applied?.effort, "High")
        XCTAssertFalse(menu.saved)
        XCTAssertEqual(keys(pane).last, "s")
    }

    func testOpenGoesBackFromCodexsListOfLevels() {
        let menu = FakeModelMenu.codex()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        XCTAssertEqual(run(.model(n: 1, label: "GPT-6.1-Sol"), pane).status, 200)
        // The phone asks again: nothing is typed, the same menu is read.
        let again = run(.open, pane)
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(labels(again.body, "models"), menu.models.map(\.label))
        XCTAssertEqual(pane.argv.filter { $0.first == "load-buffer" }.count, 1)
        XCTAssertFalse(menu.saved)
    }

    // MARK: refusals

    func testABusyPaneIsNotAsked() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        let refused = run(.open, pane, status: .busy)
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(refused.body["error"] as? String, "busy")
        XCTAssertTrue(pane.argv.isEmpty)
    }

    func testAnAgentThatOpensNoMenuIsReported() {
        let pane = FakePane()
        pane.screenAfterPaste = DemoPrompt.input(MobileModel.command)
        let refused = run(.open, pane)
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(refused.body["error"] as? String, "no_menu")
    }

    func testAModelThatIsNotWhereThePhoneSawItClosesTheMenu() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        let refused = run(.model(n: 5, label: "Opus 5.5"), pane)
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(refused.body["error"] as? String, "changed")
        XCTAssertFalse(menu.isOpen)
        XCTAssertNil(menu.applied)
    }

    func testApplyForAnotherModelThanTheCursorsClosesTheMenu() {
        let menu = FakeModelMenu.claude()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        XCTAssertEqual(run(.model(n: 3, label: "Fable 5.1"), pane).status, 200)
        let refused = run(.apply(model: "Haiku 5.5", effort: "Low"), pane)
        XCTAssertEqual(refused.body["error"] as? String, "changed")
        XCTAssertFalse(menu.isOpen)
        XCTAssertNil(menu.applied)
    }

    func testALevelTheModelLacksIsRefused() {
        let menu = FakeModelMenu.codex()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        XCTAssertEqual(run(.model(n: 2, label: "GPT-6-Astra"), pane).status, 200)
        for effort in ["Max", "More reasoning…"] {
            let refused = run(.apply(model: "GPT-6-Astra", effort: effort), pane)
            XCTAssertEqual(refused.body["error"] as? String, refused.status == 409 ? "no_effort" : "", effort)
            XCTAssertNil(menu.applied)
            _ = run(.open, pane)
            _ = run(.model(n: 2, label: "GPT-6-Astra"), pane)
        }
        XCTAssertFalse(menu.saved)
    }

    func testAMenuWithoutASessionKeyIsNeverTaken() {
        for menu in [FakeModelMenu.claude(), FakeModelMenu.codex()] {
            menu.sessionKey = false
            let pane = pane(menu)
            XCTAssertEqual(run(.open, pane).status, 200)
            let label = menu.models[0].label
            XCTAssertEqual(run(.model(n: 1, label: label), pane).status, 200)
            let refused = run(.apply(model: label, effort: "Low"), pane)
            XCTAssertEqual(refused.status, 409)
            XCTAssertEqual(refused.body["error"] as? String, "no_session")
            XCTAssertFalse(menu.isOpen)
            XCTAssertNil(menu.applied)
            XCTAssertFalse(menu.saved)
        }
    }

    func testCancelClosesTheMenuFromEitherList() {
        let menu = FakeModelMenu.codex()
        let pane = pane(menu)
        XCTAssertEqual(run(.open, pane).status, 200)
        XCTAssertEqual(run(.model(n: 1, label: "GPT-6.1-Sol"), pane).status, 200)
        XCTAssertEqual(run(.cancel, pane).status, 200)
        XCTAssertFalse(menu.isOpen)
        XCTAssertNil(menu.applied)
        // With no menu in front, no key is pressed.
        let before = pane.argv.count
        XCTAssertEqual(run(.cancel, pane).status, 200)
        XCTAssertEqual(pane.argv.count, before)
    }

    func testWithoutAMenuNothingIsPickedOrApplied() {
        let pane = FakePane()
        for request in [MobileModel.Request.model(n: 1, label: "Opus 5.5"), .apply(model: "Opus 5.5", effort: nil)] {
            let refused = run(request, pane)
            XCTAssertEqual(refused.status, 409)
            XCTAssertEqual(refused.body["error"] as? String, "no_menu")
        }
        XCTAssertTrue(pane.argv.isEmpty)
    }
}
