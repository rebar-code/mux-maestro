import XCTest

// BeamTransfer.swift + SshConfig.swift + TmuxModel.swift are compiled into this
// test target, so the beam env/argv construction for each direction, the up-front
// guard matrix, and the pane → Claude-session-id parse can be asserted with no
// beam.sh / ssh / tmux ever spawned.

final class BeamTransferTests: XCTestCase {
    private let remote = Host(name: "buildbox", sshAlias: "buildbox")

    private func req(
        mode: BeamTransfer.Mode, host: Host? = nil,
        dir: String = "/Users/j/code/app", sid: String? = "3f2c-abc"
    ) -> BeamTransfer.Request {
        BeamTransfer.Request(
            mode: mode, host: host ?? remote, localDir: dir, claudeSessionId: sid)
    }

    // MARK: env — push takeover (local → server)

    func testPushTakeoverSyncsResumesAndHandsOverPane() {
        let env = BeamTransfer.env(for: req(mode: .pushTakeover(paneId: "%12")))
        XCTAssertEqual(env["BEAM_HANDOFF"], "takeover")
        XCTAssertEqual(env["BEAM_PANE"], "%12")
        XCTAssertEqual(env["BEAM_CONFLICT"], "skip")
        XCTAssertEqual(env["BEAM_OPTS"], "Claude history")
        XCTAssertEqual(env["BEAM_RESUME_SID"], "3f2c-abc")
    }

    func testPushTakeoverRepoOnlyWhenNoSession() {
        let env = BeamTransfer.env(for: req(mode: .pushTakeover(paneId: "%12"), sid: nil))
        XCTAssertEqual(env["BEAM_OPTS"], "")
        XCTAssertNil(env["BEAM_RESUME_SID"])
        XCTAssertEqual(env["BEAM_HANDOFF"], "takeover")
    }

    // MARK: env — push detach (relay leg 2) and pull (server → local)

    func testPushDetachStandsUpDetachedNoPane() {
        let env = BeamTransfer.env(for: req(mode: .pushDetach))
        XCTAssertEqual(env["BEAM_HANDOFF"], "detach")
        XCTAssertNil(env["BEAM_PANE"], "detach has no pane to hand over")
        XCTAssertEqual(env["BEAM_RESUME_SID"], "3f2c-abc")
    }

    func testPullHasNoHandoff() {
        let env = BeamTransfer.env(for: req(mode: .pull))
        XCTAssertNil(env["BEAM_HANDOFF"], "pull transports only; app resumes locally")
        XCTAssertNil(env["BEAM_PANE"])
        XCTAssertEqual(env["BEAM_OPTS"], "Claude history")
        XCTAssertEqual(env["BEAM_RESUME_SID"], "3f2c-abc")
    }

    // MARK: invocation — verb per direction

    func testInvocationVerbPushVsPull() {
        let push = BeamTransfer.invocation(
            scriptPath: "/b/beam.sh", req: req(mode: .pushTakeover(paneId: "%1")))
        XCTAssertEqual(push.args, ["/b/beam.sh", "push", "buildbox"])
        let detach = BeamTransfer.invocation(scriptPath: "/b/beam.sh", req: req(mode: .pushDetach))
        XCTAssertEqual(detach.args, ["/b/beam.sh", "push", "buildbox"])
        let pull = BeamTransfer.invocation(scriptPath: "/b/beam.sh", req: req(mode: .pull))
        XCTAssertEqual(pull.args, ["/b/beam.sh", "pull", "buildbox"])
        XCTAssertEqual(pull.path, "/bin/bash")
    }

    // MARK: reject (up-front guard matrix)

    func testRejectPassesValidRemotePeer() {
        XCTAssertNil(BeamTransfer.reject(req(mode: .pull), home: "/Users/j"))
    }

    func testRejectLocalPeer() {
        XCTAssertEqual(
            BeamTransfer.reject(req(mode: .pull, host: .local), home: "/Users/j"), .localPeer)
    }

    func testRejectRemoteWithoutAlias() {
        let noAlias = Host(name: "ghost", sshAlias: "")
        XCTAssertEqual(BeamTransfer.reject(req(mode: .pull, host: noAlias), home: "/Users/j"), .noSshAlias)
    }

    func testRejectEmptyDir() {
        XCTAssertEqual(BeamTransfer.reject(req(mode: .pull, dir: ""), home: "/Users/j"), .emptyDir)
    }

    func testRejectHomeDirectory() {
        XCTAssertEqual(
            BeamTransfer.reject(req(mode: .pull, dir: "/Users/j"), home: "/Users/j"), .homeDir)
        XCTAssertEqual(
            BeamTransfer.reject(req(mode: .pull, dir: "/Users/j/"), home: "/Users/j"), .homeDir)
    }

    func testRejectAllowsSubdirOfHome() {
        XCTAssertNil(BeamTransfer.reject(req(mode: .pull, dir: "/Users/j/code"), home: "/Users/j"))
    }

    // MARK: pane → Claude session id parse (the beam linchpin)

    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    func testParsePaneSessionIdsMapsPaneToSessionId() {
        let data = json("""
        [{"pane":"%30","sessionId":"aaa","status":"busy","tmuxSession":"web"},
         {"pane":"%31","sessionId":"bbb","status":"idle","tmuxSession":"api"}]
        """)
        let map = TmuxModel.parsePaneSessionIds(fromSessionsJSON: data)
        XCTAssertEqual(map["%30"], "aaa")
        XCTAssertEqual(map["%31"], "bbb")
    }

    func testParsePaneSessionIdsSkipsEntriesMissingPaneOrId() {
        let data = json("""
        [{"sessionId":"aaa","status":"busy"},
         {"pane":"%31","status":"idle"},
         {"pane":"%32","sessionId":"","status":"idle"}]
        """)
        XCTAssertTrue(TmuxModel.parsePaneSessionIds(fromSessionsJSON: data).isEmpty)
    }

    func testParsePaneSessionIdsBusiestWinsOnCollision() {
        let data = json("""
        [{"pane":"%30","sessionId":"idle-one","status":"idle"},
         {"pane":"%30","sessionId":"waiting-one","status":"waiting"}]
        """)
        XCTAssertEqual(
            TmuxModel.parsePaneSessionIds(fromSessionsJSON: data)["%30"], "waiting-one")
    }
}
