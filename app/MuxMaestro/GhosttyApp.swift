import Cocoa
import GhosttyKit

/// Thin wrapper around the libghostty global app (`ghostty_app_t`).
///
/// The libghostty embedding C API and the correct init sequence are reused from
/// Ghostty's own macOS app (macos/Sources/Ghostty/Ghostty.App.swift): create a
/// config, create a runtime config wiring the required callbacks, then
/// `ghostty_app_new`. There is exactly one of these for the whole process.
final class GhosttyApp {
    /// The underlying libghostty app handle.
    private(set) var app: ghostty_app_t?

    /// The libghostty config handle. Owned for the app lifetime.
    private var config: ghostty_config_t?

    /// A second config handle themed for the Manager rail terminal (a distinct
    /// `background`), built lazily on first use and owned for the app lifetime.
    private var managerConfigHandle: ghostty_config_t?

    init?() {
        // Build the libghostty configuration. We load the user's default
        // Ghostty config files if present, then finalize.
        guard let cfg = ghostty_config_new() else {
            NSLog("MuxMaestro: ghostty_config_new failed")
            return nil
        }
        ghostty_config_load_default_files(cfg)

        // Force window-vsync off. libghostty's vsync path creates a legacy
        // CVDisplayLink via CVDisplayLinkCreateWithActiveCGDisplays(), which
        // fails when libghostty is embedded in a host app like this (the call
        // returns an error that libghostty maps to error.OutOfMemory, making
        // ghostty_surface_new fail). With vsync off, libghostty relies on the
        // host to drive draws — which we do via the app tick timer + the RENDER
        // action callback. We load this as an override file AFTER the user's
        // config so their settings are still respected.
        if let overridePath = Self.writeVsyncOverride() {
            ghostty_config_load_file(cfg, overridePath)
        }

        ghostty_config_finalize(cfg)
        self.config = cfg

        // Runtime config: libghostty calls back into us for app-level events.
        // wakeup_cb is invoked (possibly off the main thread) when libghostty
        // has work to do; we hop to the main thread and tick the app. action_cb
        // handles app/surface actions — most importantly RENDER, which asks us
        // to draw a surface.
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyApp.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, _, state in
                GhosttyApp.readClipboard(userdata, state: state) },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, content, len, _ in
                GhosttyApp.writeClipboard(content, len: len) },
            close_surface_cb: { _, _ in }
        )

        guard let app = ghostty_app_new(&runtimeConfig, cfg) else {
            NSLog("MuxMaestro: ghostty_app_new failed")
            return nil
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        if let managerConfigHandle { ghostty_config_free(managerConfigHandle) }
    }

    /// Give a surface the Manager theme (a distinct terminal `background`) via a
    /// per-surface config override, so the ambient agent terminal reads as its
    /// own zone rather than sharing the main terminal's theme. Re-applied on every
    /// swap (restart recreates the surface), so the manager stays themed.
    func applyManagerTheme(to surface: TerminalSurfaceView) {
        guard let cfg = managerConfig(), let handle = surface.surfaceHandle else { return }
        ghostty_surface_update_config(handle, cfg)
    }

    /// Build (once) the Manager terminal's config: the user's defaults + our vsync
    /// override + a manager theme override (a distinct `background`), finalized.
    private func managerConfig() -> ghostty_config_t? {
        if let managerConfigHandle { return managerConfigHandle }
        guard let cfg = ghostty_config_new() else {
            NSLog("MuxMaestro: manager ghostty_config_new failed")
            return nil
        }
        ghostty_config_load_default_files(cfg)
        if let overridePath = Self.writeVsyncOverride() {
            ghostty_config_load_file(cfg, overridePath)
        }
        if let themePath = Self.writeManagerTheme() {
            ghostty_config_load_file(cfg, themePath)
        }
        ghostty_config_finalize(cfg)
        managerConfigHandle = cfg
        return cfg
    }

    /// Pump libghostty. Safe to call frequently; libghostty no-ops when idle.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// Write a tiny override config (`window-vsync = false` + a little inner
    /// padding so terminal text doesn't run against the surface edges) and return
    /// its path, or nil on failure.
    private static func writeVsyncOverride() -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick", isDirectory: true)
        let url = dir.appendingPathComponent("ghostty-override.conf")
        let config = """
            window-vsync = false
            window-padding-x = 10
            window-padding-y = 8
            window-padding-balance = true

            """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            NSLog("MuxMaestro: failed to write vsync override: \(error)")
            return nil
        }
    }

    /// Write the Manager terminal's theme override (just a distinct `background`,
    /// drawn from `Theme.current.managerSurface`) and return its path, or nil on
    /// failure. Loaded after the user's config so it wins for the manager surface.
    private static func writeManagerTheme() -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick", isDirectory: true)
        let url = dir.appendingPathComponent("ghostty-manager.conf")
        let config = """
            background = \(Theme.hexString(Theme.current.managerSurface))

            """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            NSLog("MuxMaestro: failed to write manager theme: \(error)")
            return nil
        }
    }

    // MARK: libghostty callbacks

    /// Paste: hand libghostty the system pasteboard's text to complete the paste
    /// request against the requesting surface. `confirmed: true` skips
    /// libghostty's paste-confirmation path (we have no dialog wired). userdata is
    /// the SURFACE userdata (a TerminalSurfaceView).
    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata else { return false }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surfaceHandle,
              let str = NSPasteboard.general.string(forType: .string), !str.isEmpty
        else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        return true
    }

    /// Copy: write libghostty's clipboard content (the selection) to the system
    /// pasteboard. Takes the first text/plain entry.
    private static func writeClipboard(
        _ content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int
    ) {
        guard let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let dataPtr = item.data else { continue }
            let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
            guard mime == "text/plain" else { continue }
            let text = String(cString: dataPtr)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
        // wakeup may fire on a background thread; tick on the main thread.
        DispatchQueue.main.async { app.tick() }
    }

    /// The view behind a surface-targeted action, from the surface userdata.
    private static func surfaceView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            // Ask the target surface to draw. We resolve the surface view from
            // the surface userdata pointer (set in the surface config).
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surface = target.target.surface,
               let ud = ghostty_surface_userdata(surface) {
                let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
                view.requestDraw()
                return true
            }
            return false

        case GHOSTTY_ACTION_OPEN_URL:
            // A ⌘-clicked link. Unhandled ⇒ Ghostty falls back to `open <url>`.
            guard let view = surfaceView(target), let ptr = action.action.open_url.url
            else { return false }
            let bytes = UnsafeRawBufferPointer(start: ptr, count: Int(action.action.open_url.len))
            return view.onOpenLink?(String(decoding: bytes, as: UTF8.self)) ?? false

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // Ghostty sends the pointer shape on entering a link and the
            // terminal's shape on leaving it — drive the hand cursor from that.
            guard let view = surfaceView(target) else { return false }
            view.setOverLink(action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_POINTER)
            return true

        default:
            // Everything else (title, pwd, cell size, etc.) is unhandled for M2.
            return false
        }
    }
}
