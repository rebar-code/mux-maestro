import Network
import XCTest

/// The client the phone server tests reach their loopback listeners with.
///
/// Each connection is made from a new local port, and a closed connection
/// keeps its port for 30 s. The system has 16 384 of them, so when test runs,
/// dev servers and browsers on one machine close more than that in 30 s, a
/// connect fails with "Address already in use" until some come free. A client
/// that only waits for a reply then gets none and reads as a server that did
/// not answer. Here the connect is tried again until a port is free: nothing
/// was sent, so asking again cannot repeat a write.
enum LoopbackClient {
    /// How long a closed TCP connection keeps its local port (twice the
    /// system's 15 s segment lifetime), and a little more.
    static let portWait: TimeInterval = 35
    static let retryPause: TimeInterval = 0.5

    enum Connected {
        case open(NWConnection)
        /// Nothing listens on the port, or it did not answer the connect.
        case refused
        /// No local port came free within the wait.
        case noLocalPort
    }

    private enum Opening {
        case ready, refused, noLocalPort
    }

    /// A connection to `127.0.0.1:port` that has opened, started on `queue`.
    /// `localPort` pins the port it connects from, for the tests of this
    /// client itself.
    static func connect(
        port: Int, queue: DispatchQueue, localPort: Int? = nil, wait: TimeInterval = portWait,
        timeout: TimeInterval = 5
    ) -> Connected {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let parameters = NWParameters.tcp
            if let localPort, let local = NWEndpoint.Port(rawValue: UInt16(clamping: localPort)) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local)
            }
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!,
                using: parameters)
            switch open(connection, on: queue, timeout: timeout) {
            case .ready:
                return .open(connection)
            case .refused:
                connection.cancel()
                return .refused
            case .noLocalPort:
                connection.cancel()
                guard Date() < deadline else { return .noLocalPort }
                Thread.sleep(forTimeInterval: retryPause)
            }
        }
    }

    /// Start `connection` and wait until it has opened or cannot.
    private static func open(
        _ connection: NWConnection, on queue: DispatchQueue, timeout: TimeInterval
    ) -> Opening {
        let settled = DispatchSemaphore(value: 0)
        // Read and written on `queue` only.
        var opening: Opening?
        connection.stateUpdateHandler = { state in
            guard opening == nil else { return }
            switch state {
            case .ready:
                opening = .ready
            case .waiting(let error), .failed(let error):
                switch error {
                case .posix(.EADDRINUSE), .posix(.EADDRNOTAVAIL): opening = .noLocalPort
                case .posix(.ECONNREFUSED): opening = .refused
                default: return
                }
            default:
                return
            }
            settled.signal()
        }
        connection.start(queue: queue)
        _ = settled.wait(timeout: .now() + timeout)
        let result = queue.sync { opening }
        connection.stateUpdateHandler = nil
        return result ?? .refused
    }

    /// Send `data` to `127.0.0.1:port` and read until `done` says the reply is
    /// whole, the server hangs up, or `timeout` passes. Empty when nothing
    /// listens. A machine with no free local port for the whole wait fails
    /// the test by name instead of looking like a silent server.
    static func exchange(
        port: Int, send data: Data, label: String, maximumLength: Int = 65_536,
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        until done: @escaping (Data) -> Bool
    ) -> Data {
        let queue = DispatchQueue(label: label)
        let connection: NWConnection
        switch connect(port: port, queue: queue, timeout: timeout) {
        case .open(let opened): connection = opened
        case .refused: return Data()
        case .noLocalPort:
            XCTFail("no free local port in \(Int(portWait)) s", file: file, line: line)
            return Data()
        }
        let finished = DispatchSemaphore(value: 0)
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                chunk, _, complete, error in
                if let chunk { received.append(chunk) }
                if complete || error != nil || done(received) { finished.signal() } else { read() }
            }
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
        read()
        _ = finished.wait(timeout: .now() + timeout)
        connection.cancel()
        return queue.sync { received }
    }
}

final class LoopbackClientTests: XCTestCase {
    /// A listener on a port the system picks; it accepts and says nothing.
    /// It hangs up when the client does: a connection left half open would
    /// keep the client's port taken long after the test.
    private func listener() throws -> (listener: NWListener, port: Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { accepted in
            accepted.start(queue: .global())
            accepted.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                accepted.cancel()
            }
        }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, Int(try XCTUnwrap(listener.port).rawValue))
    }

    /// The failure the CI run hit, made on purpose: the local port the client
    /// must connect from is taken. A client that does not wait gets no
    /// connection; one that waits gets it as soon as the port is free.
    func testAConnectWhoseLocalPortIsTakenIsTriedAgainUntilThePortIsFree() throws {
        let server = try listener()
        let holder = try listener()
        defer { server.listener.cancel() }
        let queue = DispatchQueue(label: "loopback-client-tests")

        // No wait: what a client without the retry sees. Not a reply, and not
        // "nothing listens" either.
        guard case .noLocalPort = LoopbackClient.connect(
            port: server.port, queue: queue, localPort: holder.port, wait: 0)
        else { return XCTFail("a taken local port must read as no local port") }

        // The port comes free a second later; the same connect now waits for it.
        // Mostly that is the second. When the system handed the holder a port
        // that a closed connection of an earlier test still keeps, it is that
        // connection's 30 s: the very wait this client is for.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { holder.listener.cancel() }
        let started = Date()
        guard case .open(let connection) = LoopbackClient.connect(
            port: server.port, queue: queue, localPort: holder.port)
        else { return XCTFail("the connect must be tried again until the port is free") }
        connection.cancel()
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.5)
    }

    func testAPortNobodyListensOnIsRefusedAtOnce() throws {
        let gone = try listener()
        gone.listener.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        let reply = LoopbackClient.exchange(
            port: gone.port, send: Data("GET / HTTP/1.1\r\n\r\n".utf8), label: "loopback-client-tests"
        ) { _ in false }
        XCTAssertEqual(reply, Data())
        // Refused is not waited out: only a missing local port is.
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }
}
