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
