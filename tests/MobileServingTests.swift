import XCTest

// MobileServing.swift compiles into this test target: the rules for publishing
// a dev server on the tailnet, and the Running list as the phone gets it.
final class MobileServingTests: XCTestCase {
    private func server(_ port: Int, url: String?, host: String = Running.localHostName) -> RunningResource {
        RunningResource(
            kind: .server(port: port), host: host, paneID: "%12", label: "acme-app",
            tooltip: "", url: url, pid: 4242, dir: "/Users/me/acme-app")
    }

    private func stack(host: String = Running.localHostName) -> RunningResource {
        let name = host == Running.localHostName ? "localhost" : "devbox.example.ts.net"
        return RunningResource(
            kind: .container(name: "acme-app", ports: [54321, 54322, 54323], count: 10),
            host: host, paneID: "%12", label: "acme-app", tooltip: "",
            url: "http://\(name):54323",
            links: [
                RunningLink(label: "Studio", url: "http://\(name):54323", action: .open),
                RunningLink(label: "API", url: "http://\(name):54321", action: .open),
                RunningLink(
                    label: "DB", url: "postgresql://postgres:postgres@\(name):54322/postgres",
                    action: .copy),
            ],
            isSupabaseStack: true)
    }

    private func container() -> RunningResource {
        RunningResource(
            kind: .container(name: "mailpit", ports: [1025, 8025], count: 1),
            host: Running.localHostName, paneID: "%12", label: "mailpit", tooltip: "",
            url: "http://localhost:1025",
            links: [
                RunningLink(label: "", url: "http://localhost:1025", action: .open),
                RunningLink(label: "", url: "http://localhost:8025", action: .open),
            ])
    }

    func testOnlyAnUnprivilegedPortThatIsNotThePhoneServersOwnIsAllowed() {
        XCTAssertTrue(MobileServing.allowed(port: 5173, ownPort: 7433))
        XCTAssertTrue(MobileServing.allowed(port: 1024, ownPort: 7433))
        XCTAssertTrue(MobileServing.allowed(port: 65535, ownPort: nil))
        for port in [7433, 0, 1, 22, 80, 443, 1023, -1, 65536, 70000] {
            XCTAssertFalse(MobileServing.allowed(port: port, ownPort: 7433), "\(port)")
        }
    }

    func testTheServeCommandProxiesToLocalhostOnTheTailnetOnly() {
        XCTAssertEqual(
            MobileServing.serveOnArgv(port: 5173, https: false),
            ["serve", "--bg", "--https=5173", "http://localhost:5173"])
        XCTAssertEqual(
            MobileServing.serveOnArgv(port: 5173, https: true),
            ["serve", "--bg", "--https=5173", "https+insecure://localhost:5173"])
        XCTAssertEqual(MobileTailnet.serveOffArgv(port: 5173), ["serve", "--https=5173", "off"])
        for https in [false, true] {
            let argv = MobileServing.serveOnArgv(port: 5173, https: https)
            XCTAssertFalse(argv.contains { $0.contains("funnel") })
            XCTAssertEqual(argv.first, "serve")
        }
    }

    func testWhoHoldsAPortIsReadFromTheServeStatus() {
        let web = { (proxy: String) in
            #"{"TCP":{"5173":{"HTTPS":true}},"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":""#
                + proxy + #""}}}}}"#
        }
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: "{}", port: 5173), .nobody)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: web("http://localhost:5173"), port: 5173), .ours)
        XCTAssertEqual(
            MobileServing.holder(serveStatusJSON: web("https+insecure://localhost:5173"), port: 5173), .ours)
        // Another port's mapping says nothing about this one.
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: web("http://localhost:5173"), port: 6006), .nobody)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: web("http://localhost:5173"), port: 173), .nobody)
        for proxy in [
            "http://127.0.0.1:5173", "http://localhost:3000", "http://localhost:51730",
            "https://localhost:5173", "http://devbox:5173",
        ] {
            XCTAssertEqual(MobileServing.holder(serveStatusJSON: web(proxy), port: 5173), .other, proxy)
        }
        // A file or text handler has no proxy at all.
        XCTAssertEqual(
            MobileServing.holder(
                serveStatusJSON: #"{"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Path":"/Users/me"}}}}}"#,
                port: 5173),
            .other)
        // A raw TCP forward.
        XCTAssertEqual(
            MobileServing.holder(serveStatusJSON: #"{"TCP":{"5173":{"TCPForward":"127.0.0.1:22"}}}"#, port: 5173),
            .other)
        // Open to the internet: never ours, even with our own target.
        let funnel = #"{"AllowFunnel":{"devmac.example.ts.net:5173":true},"Web":{"devmac.example.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://localhost:5173"}}}}}"#
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: funnel, port: 5173), .other)
        // A status that cannot be read proves nothing.
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: "not json", port: 5173), .other)
    }

    /// What `tailscale serve status --json` answers on a Mac with four
    /// mappings, with the names replaced. Every HTTPS mapping has a `TCP`
    /// entry as well as its `Web` handler, and there is no `AllowFunnel` key
    /// while nothing is funnelled.
    private static let recorded = """
        {"TCP":{"443":{"HTTPS":true},"5174":{"HTTPS":true},"5175":{"HTTPS":true},"7433":{"HTTPS":true}},
         "Web":{"devmac.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}},
                "devmac.example.ts.net:5174":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5174"}}},
                "devmac.example.ts.net:5175":{"Handlers":{"/":{"Proxy":"https+insecure://localhost:5175"}}},
                "devmac.example.ts.net:7433":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7433"}}}}}
        """

    func testTheRecordedServeStatusIsReadAsItIs() throws {
        let status = Self.recorded
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 5174), .other)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 5175), .ours)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 443), .other)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 7433), .other)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 9999), .nobody)
        // 75 is the tail of 5175 and a port of its own.
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: status, port: 75), .nobody)
        XCTAssertEqual(MobileServing.proxy(serveStatusJSON: status, port: 5175), "https+insecure://localhost:5175")
        XCTAssertNil(MobileServing.proxy(serveStatusJSON: status, port: 9999))

        // The phone server's own mapping, as PR 1 reads it.
        XCTAssertTrue(MobileTailnet.servesOurs(serveStatusJSON: status, port: 7433))
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: status, port: 7433))
        // A port that proxies elsewhere, or to `localhost`, is someone else's.
        XCTAssertTrue(MobileTailnet.portTaken(serveStatusJSON: status, port: 443))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: status, port: 443))
        XCTAssertTrue(MobileTailnet.portTaken(serveStatusJSON: status, port: 5175))
        XCTAssertFalse(MobileTailnet.servesOurs(serveStatusJSON: status, port: 5175))
        // The phone server's own form is `127.0.0.1` on the same port: for the
        // port it is set to, such a mapping reads as its own leftover.
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: status, port: 5174))
        XCTAssertFalse(MobileTailnet.portTaken(serveStatusJSON: status, port: 9999))

        // A raw TCP forward has a `TCP` entry and no handler.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        var tcp = try XCTUnwrap(object["TCP"] as? [String: Any])
        tcp["2222"] = ["TCPForward": "127.0.0.1:22"]
        object["TCP"] = tcp
        // The funnel list names a port as the handlers do: `host:port`.
        object["AllowFunnel"] = ["devmac.example.ts.net:5175": true, "devmac.example.ts.net:5174": false]
        let changed = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: changed, port: 2222), .other)
        XCTAssertTrue(MobileTailnet.portTaken(serveStatusJSON: changed, port: 2222))
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: changed, port: 5175), .other)
        XCTAssertNil(MobileServing.proxy(serveStatusJSON: changed, port: 5175))
        // A port whose funnel is off is judged by its handler alone.
        XCTAssertEqual(MobileServing.holder(serveStatusJSON: changed, port: 5174), .other)
        // The CLI's keys with a null value, as Go writes an empty map.
        XCTAssertEqual(
            MobileServing.holder(serveStatusJSON: #"{"TCP":null,"Web":null,"AllowFunnel":null}"#, port: 5175),
            .nobody)
    }

    // MARK: the sweep

    private func tree(panes: [String]) -> MobileSnapshot {
        MobileSnapshot.build([MobileHostInput(
            host: .local, colorHex: "#3291ff", reachability: .reachable, stats: nil,
            sessions: [TmuxSession(name: "acme-app", attached: true, windows: panes.enumerated().map {
                TmuxWindow(index: $0.offset + 1, name: "w", active: $0.offset == 0, panes: [
                    TmuxPane(id: $0.element, index: 0, command: "zsh", title: "", active: true),
                ])
            })])])
    }

    func testAMappingIsGoneOnceItsThreadLeftOrItsServerStopped() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mapping = { (port: Int, thread: String) in
            MobilePortMapping(port: port, thread: thread, label: "acme-app", https: false, openedAt: start)
        }
        let mappings = [
            mapping(5173, "localhost:12"), mapping(6006, "localhost:12"), mapping(8080, "localhost:13"),
            mapping(9000, "localhost:14"), mapping(4000, "localhost:99"),
        ]
        var asked: [String] = []
        let gone = MobileServing.gone(
            mappings, snapshot: tree(panes: ["%12", "%13", "%14"]),
            running: { thread in
                asked.append(thread.id)
                switch thread.id {
                // Known, and 6006 is no longer in it.
                case "localhost:12":
                    return RunningSet(known: true, resources: [server(5173, url: "http://localhost:5173")], unknowns: [])
                // Not known yet: an empty list is not "nothing runs".
                case "localhost:13":
                    return RunningSet(known: false, resources: [], unknowns: ["ports not checked yet on localhost"])
                // The pane was not found for the scan: that proves nothing either.
                default:
                    return nil
                }
            }, ownPort: 7433)
        // 6006 stopped; the thread of 4000 left the tree.
        XCTAssertEqual(gone, [6006, 4000])
        // A thread that left is not asked about.
        XCTAssertFalse(asked.contains("localhost:99"))

        // The phone server's own port is never a server of a thread.
        let own = MobileServing.gone(
            [mapping(7433, "localhost:12")], snapshot: tree(panes: ["%12"]),
            running: { _ in
                RunningSet(known: true, resources: [self.server(7433, url: "http://localhost:7433")], unknowns: [])
            }, ownPort: 7433)
        XCTAssertEqual(own, [7433])
        XCTAssertEqual(
            MobileServing.gone([], snapshot: tree(panes: []), running: { _ in nil }, ownPort: nil), [])
    }

    func testAnOpenRequestTakesAThreadAndAnIntegerPortAndNothingElse() {
        let ask = MobileServing.openRequest(Data(#"{"thread":"localhost:12","port":5173}"#.utf8))
        XCTAssertEqual(ask?.thread, "localhost:12")
        XCTAssertEqual(ask?.port, 5173)
        for body in [
            "", "[]", "5173", #"{"port":5173}"#, #"{"thread":"localhost:12"}"#,
            #"{"thread":"localhost:12","port":"5173"}"#, #"{"thread":"localhost:12","port":true}"#,
            #"{"thread":"localhost:12","port":5173.5}"#, #"{"thread":"localhost:12","port":5173.0}"#,
            #"{"thread":"localhost:12","port":-1}"#, #"{"thread":"localhost:12","port":65536}"#,
            #"{"thread":"localhost:12","port":99999999999999999999}"#,
            #"{"thread":"localhost:12","port":null}"#, #"{"thread":"localhost:12","port":[5173]}"#,
            #"{"thread":"localhost:12","port":"evil.example:443"}"#,
            #"{"thread":12,"port":5173}"#,
        ] {
            XCTAssertNil(MobileServing.openRequest(Data(body.utf8)), body)
        }
        XCTAssertEqual(MobileServing.closeRequest(Data(#"{"port":5173}"#.utf8)), 5173)
        XCTAssertNil(MobileServing.closeRequest(Data(#"{"port":"5173"}"#.utf8)))
        XCTAssertNil(MobileServing.closeRequest(Data(#"{"port":true}"#.utf8)))
    }

    func testTheRunningListNamesPortsAndNeverAConnectionString() throws {
        let set = RunningSet(
            known: false,
            resources: [
                server(5173, url: "https://localhost:5173"), server(6006, url: "http://localhost:6006"),
                server(7433, url: "http://localhost:7433"), server(80, url: "http://localhost:80"),
                server(7000, url: nil, host: "devbox"), stack(), stack(host: "devbox"), container(),
            ],
            unknowns: ["Docker unavailable on devbox"])
        let json = MobileServing.runningJSON(set, ownPort: 7433)
        let text = String(
            decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertFalse(text.contains("postgres"))
        XCTAssertFalse(text.contains("://"))
        XCTAssertEqual(json["known"] as? Bool, false)
        XCTAssertEqual(json["unknowns"] as? [String], ["Docker unavailable on devbox"])

        let servers = try XCTUnwrap(json["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.map { $0["port"] as? Int }, [5173, 6006, 7433, 80, 7000])
        XCTAssertEqual(servers.map { $0["https"] as? Bool }, [true, false, false, false, false])
        // Not the phone server's own port, not a privileged one, not another host's.
        XCTAssertEqual(servers.map { $0["mappable"] as? Bool }, [true, true, false, false, false])
        XCTAssertEqual(servers[0]["key"] as? String, "localhost|server|5173")
        XCTAssertEqual(servers[0]["label"] as? String, "acme-app")
        XCTAssertEqual(servers[4]["local"] as? Bool, false)

        let stacks = try XCTUnwrap(json["stacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.count, 2)
        XCTAssertEqual(stacks[0]["count"] as? Int, 10)
        let links = try XCTUnwrap(stacks[0]["links"] as? [[String: Any]])
        XCTAssertEqual(links.map { $0["label"] as? String }, ["Studio", "API", "DB"])
        XCTAssertEqual(links.map { $0["port"] as? Int }, [54323, 54321, 54322])
        XCTAssertEqual(links.map { $0["open"] as? Bool }, [true, true, false])
        XCTAssertEqual(links.map { $0["mappable"] as? Bool }, [true, true, false])
        let remote = try XCTUnwrap(stacks[1]["links"] as? [[String: Any]])
        XCTAssertEqual(remote.map { $0["mappable"] as? Bool }, [false, false, false])

        let containers = try XCTUnwrap(json["containers"] as? [[String: Any]])
        XCTAssertEqual(containers.count, 1)
        XCTAssertEqual(
            (containers[0]["links"] as? [[String: Any]])?.map { $0["port"] as? Int }, [1025, 8025])

        // What an open request is checked against: the same rule, one place.
        let mappable = MobileServing.mappable(in: set, ownPort: 7433)
        XCTAssertEqual(mappable.keys.sorted(), [1025, 5173, 6006, 8025, 54321, 54323])
        XCTAssertEqual(mappable[5173]?.https, true)
        XCTAssertEqual(mappable[6006]?.https, false)
        XCTAssertEqual(mappable[54323]?.label, "acme-app Studio")
    }

    func testAMappingIsStaleOnceItsServerIsGoneOrNobodyOpenedItForHalfAnHour() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mappings = [5173, 6006, 54323].map {
            MobilePortMapping(port: $0, thread: "localhost:12", label: "acme-app", https: false, openedAt: start)
        }
        XCTAssertEqual(MobileServing.idleSeconds, 1800)
        XCTAssertEqual(MobileServing.stale(mappings, gone: [], now: start.addingTimeInterval(1799)), [])
        XCTAssertEqual(MobileServing.stale(mappings, gone: [6006, 9999], now: start.addingTimeInterval(60)), [6006])
        XCTAssertEqual(
            MobileServing.stale(mappings, gone: [], now: start.addingTimeInterval(1800)), [5173, 6006, 54323])
    }

    func testTheListAndTheAnswersCarryTheTailnetAddress() throws {
        let identity = MobileIdentity(login: "me@example.com", dnsName: "devmac.example.ts.net")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let list = MobileServing.listJSON(
            [
                MobilePortMapping(port: 6006, thread: "localhost:12", label: "storybook", https: false, openedAt: start),
                MobilePortMapping(port: 5173, thread: "localhost:12", label: "acme-app", https: true, openedAt: start),
            ], identity: identity)
        XCTAssertEqual(list["max"] as? Int, 5)
        let mappings = try XCTUnwrap(list["mappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.map { $0["port"] as? Int }, [5173, 6006])
        XCTAssertEqual(mappings[0]["url"] as? String, "https://devmac.example.ts.net:5173/")
        XCTAssertEqual(mappings[0]["thread"] as? String, "localhost:12")
        XCTAssertEqual(mappings[0]["label"] as? String, "acme-app")

        let body = { (opened: MobileServing.Opened) -> (Int, String) in
            let response = MobileServing.response(opened, port: 5173, identity: identity)
            return (response.status, String(decoding: response.body, as: UTF8.self))
        }
        XCTAssertEqual(body(.ok).0, 200)
        XCTAssertEqual(body(.ok).1, #"{"port":5173,"url":"https:\/\/devmac.example.ts.net:5173\/"}"#)
        XCTAssertEqual(body(.refused).0, 403)
        XCTAssertEqual(body(.refused).1, #"{"error":"refused"}"#)
        XCTAssertEqual(body(.taken).0, 409)
        XCTAssertEqual(body(.taken).1, #"{"error":"taken"}"#)
        XCTAssertEqual(body(.limit).1, #"{"error":"limit"}"#)
        XCTAssertEqual(body(.unavailable("tailscale serve failed")).0, 503)
    }
}
