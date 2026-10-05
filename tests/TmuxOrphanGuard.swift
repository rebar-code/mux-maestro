import Foundation

/// A private tmux server is a daemon, so it outlives a test process that is
/// killed before teardown: a pane that runs `yes` then holds a core for days.
/// This is a job of the server's own that ends it once `owner` is gone.
enum TmuxOrphanGuard {
    static func argv(tmux path: String, socket name: String, owner: Int32) -> [String] {
        // tmux fills in `#{pid}` and `#{socket_path}`. The loop also ends with
        // the server, so a normal teardown leaves no shell behind. TERM is
        // ignored so the socket file is still taken away.
        let script = "trap '' TERM HUP; "
            + "while kill -0 \(owner) 2>/dev/null && kill -0 #{pid} 2>/dev/null; do sleep 1; done; "
            + "'\(path)' -L '\(name)' kill-server; rm -f '#{socket_path}'"
        return ["run-shell", "-b", script]
    }
}
