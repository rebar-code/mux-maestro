import Cocoa
import GhosttyKit

// Input encoding helpers reused (with light adaptation) from Ghostty's macOS
// app: macos/Sources/Ghostty/Ghostty.Input.swift and
// macos/Sources/Ghostty/NSEvent+Extension.swift. Ghostty is MIT licensed.
// We only need the subset that translates AppKit key/modifier events into the
// libghostty C key event so the embedded surface gets correct terminal input
// (Enter, Ctrl-C, arrows, etc. — encoded by libghostty's KeyEncoder).

enum GhosttyInput {
    /// Translate AppKit modifier flags to a libghostty mods enum.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Sided modifiers.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }
}

extension NSEvent {
    /// Build a libghostty key event for the given action. Mirrors Ghostty's
    /// NSEvent.ghosttyKeyEvent. The caller is responsible for setting `text`
    /// (it must outlive the call) since a Swift String can't be safely bridged
    /// here.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = UInt32(keyCode)
        keyEv.text = nil
        keyEv.composing = false

        keyEv.mods = GhosttyInput.mods(modifierFlags)
        // Control/command never contribute to text translation.
        keyEv.consumed_mods = GhosttyInput.mods(
            modifierFlags.subtracting([.control, .command]))

        keyEv.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEv.unshifted_codepoint = codepoint.value
            }
        }

        return keyEv
    }

    /// The text to send for a key event, with control characters stripped (we
    /// let libghostty encode control characters itself) and function-key PUA
    /// scalars filtered out. Mirrors Ghostty's NSEvent.ghosttyCharacters.
    var ghosttyCharacters: String? {
        // `characters` is only valid on key events. flagsChanged also reaches
        // here (modifier presses are forwarded to libghostty), and as of
        // macOS 26 asking a non-key event for its characters raises
        // NSInternalInconsistencyException instead of returning nil.
        guard type == .keyDown || type == .keyUp else { return nil }
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
