import XCTest

// MobileCards.swift (Foundation only) compiles into this test target: the card
// a `review_card` row decodes to, which pane a tap's answer goes to, the
// refusals, and the JSON the phone draws, with no socket and no tmux.
final class MobileCardsTests: XCTestCase {
    private func pane(
        _ id: String, claude: String? = nil, status: AttentionStatus = .idle
    ) -> TmuxPane {
        var pane = TmuxPane(id: id, index: 0, command: "claude", title: "", active: true)
        pane.claudeSessionId = claude ?? "c\(id.dropFirst())"
        pane.attention = status
        return pane
    }

    /// Two hosts. `acme-app` holds three agents in two windows; a session
    /// named `billing` is on both hosts.
    private func snapshot() -> MobileSnapshot {
        MobileSnapshot.build([
            MobileHostInput(
                host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
                sessions: [
                    TmuxSession(name: "mux-manager", attached: false, windows: [
                        TmuxWindow(index: 0, name: "maestro", active: true, panes: [pane("%1")]),
                    ]),
                    TmuxSession(name: "acme-app", attached: true, windows: [
                        TmuxWindow(index: 1, name: "checkout-fix", active: true,
                                   panes: [pane("%12"), pane("%13")]),
                        TmuxWindow(index: 2, name: "migration", active: false, panes: [pane("%14")]),
                    ]),
                    TmuxSession(name: "billing", attached: false, windows: [
                        TmuxWindow(index: 0, name: "invoices", active: true, panes: [pane("%20")]),
                    ]),
                ]),
            MobileHostInput(
                host: Host(name: "devbox", sshAlias: "devbox"), colorHex: "#f5a623",
                reachability: .reachable, stats: nil,
                sessions: [TmuxSession(name: "billing", attached: false, windows: [
                    TmuxWindow(index: 0, name: "invoices-pdf", active: true, panes: [pane("%3")]),
                ])]),
        ])
    }

    private let yesNo = [
        ManagerCard.Action(label: "Yes", text: "yes, run it"),
        ManagerCard.Action(label: "No", text: "no, stop.\nExplain why first."),
    ]

    private func card(
        session: String = "acme-app", window: Int? = nil, pane: String? = "%13",
        host: String = "localhost", actions: [ManagerCard.Action]? = nil,
        answer: ManagerCard.Answer? = nil, body: String = ""
    ) -> MobileCard {
        MobileCard(
            title: "asks whether to run the migration",
            source: MobileCard.Source(host: host, session: session, window: window, pane: pane),
            card: ManagerCard(pane: pane, body: body, actions: actions ?? yesNo, answer: answer))
    }

    private let key = "point:localhost:acme-app"

    private func board(_ card: MobileCard?) -> MobileManagerBoard {
        MobileManagerBoard(items: [
            MobileManagerItem(
                kind: .review, key: key, title: "acme-app", detail: "asks whether to run the migration",
                severity: .blocked, at: 1_759_500_000,
                link: .open(session: "acme-app", window: nil, pane: nil, host: "localhost"),
                pointer: true, card: card),
            MobileManagerItem(
                kind: .review, key: "plain", title: "billing", detail: "PR open", severity: .warn,
                at: 1_759_499_000, link: nil),
        ])
    }

    private func ask(_ action: Int, of card: MobileCard) -> MobileCards.Ask {
        MobileCards.Ask(key: key, action: action, card: MobileCards.id(key: key, card: card))
    }

    private func code(_ route: MobileCards.Route) -> String? {
        guard case .refuse(let response) = route else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return "\(response.status) \(body?["error"] as? String ?? "")"
    }

    // MARK: the row

    func testARowDecodesToTheCardMuxWrote() {
        let card = ManagerCard.row(
            version: 1, pane: "%13", body: "It adds two columns.",
            actions: #"[{"label":"Yes","text":"yes, run it"},{"label":"No","text":"no, stop.\nExplain why first."}]"#,
            answer: "Yes", answeredAt: 1_759_500_100)
        XCTAssertEqual(card, ManagerCard(
            pane: "%13", body: "It adds two columns.", actions: yesNo,
            answer: ManagerCard.Answer(label: "Yes", at: 1_759_500_100)))
        // No pane and no answer are nil, not empty strings.
        let bare = ManagerCard.row(
            version: 1, pane: "", body: "", actions: "[]", answer: "", answeredAt: nil)
        XCTAssertEqual(bare, ManagerCard())
    }

    func testARowThisBuildCannotReadIsNotACard() {
        let actions = #"[{"label":"Yes","text":"yes"}]"#
        // A later format version.
        XCTAssertNil(ManagerCard.row(
            version: 2, pane: "", body: "", actions: actions, answer: "", answeredAt: nil))
        // Actions that are not the JSON `mux` writes: no half a card.
        for broken in ["", "{}", #"[{"label":"Yes"}]"#, #"[{"label":"","text":"x"}]"#, #"["Yes"]"#] {
            XCTAssertNil(
                ManagerCard.row(
                    version: 1, pane: "", body: "", actions: broken, answer: "", answeredAt: nil),
                broken)
        }
    }

    func testAReviewRowWithNoCardRowIsNotACard() {
        let review = ManagerReviewItem(
            key: key, host: "localhost", session: "acme-app", window: 2, severity: .blocked,
            text: "asks whether to run the migration", updatedAt: 1, dismissed: false)
        XCTAssertNil(MobileCard(review))
        var carded = review
        carded.card = ManagerCard(pane: "%14", actions: yesNo)
        XCTAssertEqual(MobileCard(carded), MobileCard(
            title: "asks whether to run the migration",
            source: MobileCard.Source(host: "localhost", session: "acme-app", window: 2, pane: "%14"),
            card: ManagerCard(pane: "%14", actions: yesNo)))
    }

    // MARK: routing

    func testAnAnswerGoesToThePaneTheCardNames() throws {
        // Not the first pane of the session, and never the Maestro's own.
        let thread = try MobileCards.target(of: card().source, in: snapshot()).get()
        XCTAssertEqual(thread.id, "localhost:13")
        XCTAssertEqual(thread.pane, "%13")
        XCTAssertEqual(thread.session, "acme-app")
        // The window is not compared: a pane keeps its id when its window moves.
        let moved = try MobileCards.target(of: card(window: 9, pane: "%14").source, in: snapshot()).get()
        XCTAssertEqual(moved.pane, "%14")
    }

    func testAPaneThatIsGoneTakesNoAnswer() {
        XCTAssertEqual(MobileCards.target(of: card(pane: "%99").source, in: snapshot()), .failure(.gone))
        // The id is listed, but in another session: the tmux server restarted
        // and handed the id out again.
        XCTAssertEqual(MobileCards.target(of: card(pane: "%20").source, in: snapshot()), .failure(.gone))
        XCTAssertEqual(MobileCards.target(of: card().source, in: MobileSnapshot()), .failure(.gone))
    }

    func testWithNoPaneTheSourceMustHoldExactlyOneThread() throws {
        // Three agents in the session: no guess.
        XCTAssertEqual(
            MobileCards.target(of: card(pane: nil).source, in: snapshot()), .failure(.ambiguous))
        XCTAssertEqual(
            MobileCards.target(of: card(window: 1, pane: nil).source, in: snapshot()),
            .failure(.ambiguous))
        // One agent in the window, or in the session.
        XCTAssertEqual(
            try MobileCards.target(of: card(window: 2, pane: nil).source, in: snapshot()).get().pane,
            "%14")
        XCTAssertEqual(
            try MobileCards.target(of: card(session: "billing", pane: nil).source, in: snapshot())
                .get().id,
            "localhost:20")
        XCTAssertEqual(
            MobileCards.target(of: card(session: "reports", pane: nil).source, in: snapshot()),
            .failure(.gone))
        XCTAssertEqual(
            MobileCards.target(of: card(session: "", pane: nil).source, in: snapshot()), .failure(.gone))
    }

    func testAnAnswerStaysOnTheHostTheCardNames() throws {
        let remote = card(session: "billing", pane: nil, host: "devbox")
        XCTAssertEqual(try MobileCards.target(of: remote.source, in: snapshot()).get().id, "devbox:3")
        // The same pane id on another host is another pane.
        XCTAssertEqual(
            MobileCards.target(of: card(session: "billing", pane: "%20", host: "devbox").source,
                               in: snapshot()),
            .failure(.gone))
    }

    func testATapDeliversThatActionsTextToTheSourceThread() throws {
        let card = card()
        let route = MobileCards.route(ask(1, of: card), board: board(card), snapshot: snapshot())
        guard case .deliver(let thread, let label, let text) = route else {
            return XCTFail("not delivered: \(route)")
        }
        XCTAssertEqual(thread.pane, "%13")
        XCTAssertEqual(label, "No")
        // Every line of it: the paste path keeps a newline as text.
        XCTAssertEqual(text, "no, stop.\nExplain why first.")
    }

    func testATapThatCannotBeHonouredIsRefused() {
        let card = card()
        let snapshot = snapshot()
        // No such card, and a review row that has none.
        XCTAssertEqual(
            code(MobileCards.route(
                MobileCards.Ask(key: "nope", action: 0, card: "x"), board: board(card),
                snapshot: snapshot)),
            "404 not_found")
        XCTAssertEqual(
            code(MobileCards.route(
                MobileCards.Ask(key: "plain", action: 0, card: "x"), board: board(card),
                snapshot: snapshot)),
            "404 not_found")
        // The card the phone showed is not the card now.
        let other = self.card(actions: [ManagerCard.Action(label: "Yes", text: "yes, drop the table")])
        XCTAssertEqual(
            code(MobileCards.route(ask(0, of: card), board: board(other), snapshot: snapshot)),
            "409 changed")
        // Answered, as the row says or as this server just did.
        let answered = self.card(answer: ManagerCard.Answer(label: "Yes", at: 5))
        XCTAssertEqual(
            code(MobileCards.route(ask(0, of: answered), board: board(answered), snapshot: snapshot)),
            "409 answered")
        XCTAssertEqual(
            code(MobileCards.route(
                ask(0, of: card), board: board(card), snapshot: snapshot,
                delivered: [MobileCards.id(key: key, card: card)])),
            "409 answered")
        // Not a button on the card.
        XCTAssertEqual(
            code(MobileCards.route(ask(2, of: card), board: board(card), snapshot: snapshot)),
            "400 bad_action")
        // Its pane is gone, or cannot be told from another.
        let gone = self.card(pane: "%99")
        XCTAssertEqual(
            code(MobileCards.route(ask(0, of: gone), board: board(gone), snapshot: snapshot)),
            "404 source_gone")
        let vague = self.card(pane: nil)
        XCTAssertEqual(
            code(MobileCards.route(ask(0, of: vague), board: board(vague), snapshot: snapshot)),
            "409 source_ambiguous")
    }

    func testTextThatHoldsAKeyPressIsNeverTyped() {
        // The DB is a file: a row `mux` did not write can hold anything.
        for text in ["yes\u{1B}[A", "yes\rrm -rf", "a\u{03}", String(repeating: "x", count: 8193)] {
            let card = card(actions: [ManagerCard.Action(label: "Yes", text: text)])
            XCTAssertEqual(
                code(MobileCards.route(ask(0, of: card), board: board(card), snapshot: snapshot())),
                "400 bad_action", String(text.prefix(12)))
        }
    }

    func testTheIdNamesOneStateOfTheQuestion() {
        let base = MobileCards.id(key: key, card: card())
        XCTAssertEqual(base, MobileCards.id(key: key, card: card()))
        // An answer and a body are not the question.
        XCTAssertEqual(base, MobileCards.id(key: key, card: card(body: "More words.")))
        XCTAssertEqual(
            base, MobileCards.id(key: key, card: card(answer: ManagerCard.Answer(label: "Yes", at: 5))))
        XCTAssertNotEqual(base, MobileCards.id(key: "point:localhost:billing", card: card()))
        XCTAssertNotEqual(base, MobileCards.id(key: key, card: card(pane: "%12")))
        XCTAssertNotEqual(base, MobileCards.id(key: key, card: card(actions: [yesNo[0]])))
        XCTAssertNotEqual(
            base,
            MobileCards.id(key: key, card: card(actions: [
                yesNo[0], ManagerCard.Action(label: "No", text: "no"),
            ])))
    }

    func testAskTakesOnlyAWholeRequest() {
        XCTAssertEqual(
            MobileCards.ask(in: Data(#"{"key":"point:localhost:acme-app","action":1,"card":"abc"}"#.utf8)),
            MobileCards.Ask(key: "point:localhost:acme-app", action: 1, card: "abc"))
        for body in [
            "", "[]", #"{"key":"k","action":1}"#, #"{"key":"k","card":"abc"}"#,
            #"{"action":1,"card":"abc"}"#, #"{"key":"","action":1,"card":"abc"}"#,
            #"{"key":"k","action":-1,"card":"abc"}"#, #"{"key":"k","action":1.5,"card":"abc"}"#,
            #"{"key":"k","action":true,"card":"abc"}"#, #"{"key":"k","action":"1","card":"abc"}"#,
            #"{"key":"k","action":1,"card":""}"#,
            #"{"key":"\#(String(repeating: "k", count: 257))","action":1,"card":"abc"}"#,
        ] {
            XCTAssertNil(MobileCards.ask(in: Data(body.utf8)), body)
        }
    }

    // MARK: JSON

    func testTheCardJSONIsVersionOneAndKeepsTheTextOnTheMac() throws {
        let card = card(answer: ManagerCard.Answer(label: "Yes", at: 1_759_500_100), body: "It adds two columns.")
        let json = MobileCards.json(key: key, card: card, in: snapshot())
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, MobileCards.id(key: key, card: card))
        XCTAssertEqual(json["title"] as? String, "asks whether to run the migration")
        XCTAssertEqual(json["body"] as? String, "It adds two columns.")
        XCTAssertEqual(json["link"] as? String, "/t/localhost:13")
        // The thread the answer goes to, by its id: no tmux address.
        XCTAssertEqual(json["source"] as? String, "localhost:13")
        XCTAssertEqual(
            Set(json.keys), ["v", "id", "title", "body", "source", "actions", "link", "answered"])
        // Labels only: what a tap types never leaves the Mac.
        let actions = try XCTUnwrap(json["actions"] as? [[String: String]])
        XCTAssertEqual(actions, [["label": "Yes"], ["label": "No"]])
        let answered = try XCTUnwrap(json["answered"] as? [String: Any])
        XCTAssertEqual(answered["label"] as? String, "Yes")
        XCTAssertEqual(answered["at"] as? Int, 1_759_500_100)
    }

    func testACardWhoseSourceIsGoneHasNoLink() {
        let json = MobileCards.json(key: key, card: card(pane: "%99"), in: snapshot())
        XCTAssertTrue(json["link"] is NSNull)
        XCTAssertTrue(json["body"] is NSNull)
        XCTAssertTrue(json["answered"] is NSNull)
        XCTAssertTrue(json["source"] is NSNull)
    }

    func testACardThatCannotBeAnsweredStillOpensItsSession() {
        // Three agents and no pane named: no answer, but the pointer's thread opens.
        let json = MobileCards.json(
            key: key, card: card(pane: nil), in: snapshot(), opens: "localhost:12")
        XCTAssertTrue(json["source"] is NSNull)
        XCTAssertEqual(json["link"] as? String, "/t/localhost:12")
    }

    func testTheCardJSONIsCutToWhatAPhoneShows() throws {
        let long = String(repeating: "y", count: 60)
        let many = (1...6).map { ManagerCard.Action(label: "A\($0)", text: "a") }
            + [ManagerCard.Action(label: long, text: "a")]
        let json = MobileCards.json(
            key: key,
            card: card(actions: many, body: "one\u{202E}\n\ntwo\u{07}\n" + String(repeating: "z", count: 400)),
            in: snapshot())
        let actions = try XCTUnwrap(json["actions"] as? [[String: String]])
        XCTAssertEqual(actions.count, MobileCards.maxActions)
        let body = try XCTUnwrap(json["body"] as? String)
        XCTAssertTrue(body.hasPrefix("one\ntwo\nzzz"))
        XCTAssertEqual(body.count, MobileCards.maxBodyCharacters)
        XCTAssertTrue(body.hasSuffix("…"))
        // A label is one short line.
        let one = MobileCards.json(
            key: key, card: card(actions: [ManagerCard.Action(label: long + "\nmore", text: "a")]),
            in: snapshot())
        let label = try XCTUnwrap((one["actions"] as? [[String: String]])?.first?["label"])
        XCTAssertEqual(label.count, MobileCards.maxLabelCharacters)
        XCTAssertFalse(label.contains("\n"))
    }

    func testTheRouteToAThreadIsOnePathSegment() {
        XCTAssertEqual(MobileCards.route(toThread: "localhost:13"), "/t/localhost:13")
        XCTAssertEqual(MobileCards.route(toThread: "dev/box 1:3"), "/t/dev%2Fbox%201:3")
    }

    func testAPointerCarriesItsCardToThePhone() throws {
        let card = card()
        let live = MobileManager.live(board: board(card), snapshot: snapshot(), turn: nil)
        let points = try XCTUnwrap(live["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 1)
        let sent = try XCTUnwrap(points[0]["card"] as? [String: Any])
        XCTAssertEqual(sent["id"] as? String, MobileCards.id(key: key, card: card))
        XCTAssertEqual(sent["source"] as? String, "localhost:13")
        // A row with no card keeps the shape it always had.
        let review = try XCTUnwrap(live["review"] as? [[String: Any]])
        XCTAssertNil(review[0]["card"])
    }

    func testTheDeliveredAnswerNamesTheThread() throws {
        let thread = try MobileCards.target(of: card().source, in: snapshot()).get()
        let body = MobileCards.delivered(thread: thread, answer: ManagerCard.Answer(label: "No", at: 7))
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["thread"] as? String, "localhost:13")
        XCTAssertEqual((body["answered"] as? [String: Any])?["label"] as? String, "No")
    }

    // MARK: the route

    func testActIsAManagerWriteThatAlsoNeedsReplies() {
        func request(_ method: String) -> MobileRequest {
            let text = "\(method) /api/manager/act HTTP/1.1\r\n\r\n"
            guard case .request(let request, _) = MobileHTTP.parse(Data(text.utf8)) else {
                XCTFail("did not parse")
                return MobileRequest(method: method, path: "/")
            }
            return request
        }
        let both = MobileConfig(capabilities: [.manager, .replies])
        XCTAssertEqual(MobileAPI.route(request("POST"), config: both), .api(.managerAct))
        XCTAssertEqual(MobileAPI.route(request("GET"), config: both), .methodNotAllowed)
        // It types into a thread: the Maestro switch alone is not enough.
        XCTAssertEqual(
            MobileAPI.route(request("POST"), config: MobileConfig(capabilities: [.manager])),
            .disabled(.replies))
        XCTAssertEqual(
            MobileAPI.route(request("POST"), config: MobileConfig(capabilities: [.replies])),
            .disabled(.manager))
    }
}
