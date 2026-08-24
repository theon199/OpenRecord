import Carbon.HIToolbox
import Foundation

/// The privacy policy used by the keyboard event tap.  Printable keys are
/// recorded only when they participate in a command/control/option shortcut;
/// navigation and function keys are safe to record on their own.
public enum KeyboardCapturePolicy: Sendable {
    /// Returns whether a key with the supplied label and modifiers is safe to
    /// include in the keyboard telemetry stream.
    public static func shouldCapture(
        keyCode: UInt16,
        modifiers: [KeyModifier],
        label: String
    ) -> Bool {
        guard !label.isEmpty, !isModifierKey(keyCode: keyCode) else { return false }
        if isSafeSpecialKey(keyCode: keyCode) { return true }
        return modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    public static func isModifierKey(keyCode: UInt16) -> Bool {
        [
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Function), UInt16(kVK_CapsLock),
        ].contains(keyCode)
    }

    public static func isSafeSpecialKey(keyCode: UInt16) -> Bool {
        specialLabels[keyCode] != nil
    }

    /// Returns a stable label for keys whose character representation is not
    /// useful (or is layout-dependent), such as arrows and function keys.
    public static func specialKeyLabel(keyCode: UInt16) -> String? {
        specialLabels[keyCode]
    }

    private static let specialLabels: [UInt16: String] = {
        var labels: [UInt16: String] = [
            UInt16(kVK_Return): "Return",
            UInt16(kVK_ANSI_KeypadEnter): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Escape): "Escape",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
        ]
        let functionKeys: [(Int, UInt16)] = [
            (1, UInt16(kVK_F1)), (2, UInt16(kVK_F2)), (3, UInt16(kVK_F3)),
            (4, UInt16(kVK_F4)), (5, UInt16(kVK_F5)), (6, UInt16(kVK_F6)),
            (7, UInt16(kVK_F7)), (8, UInt16(kVK_F8)), (9, UInt16(kVK_F9)),
            (10, UInt16(kVK_F10)), (11, UInt16(kVK_F11)), (12, UInt16(kVK_F12)),
            (13, UInt16(kVK_F13)), (14, UInt16(kVK_F14)), (15, UInt16(kVK_F15)),
            (16, UInt16(kVK_F16)), (17, UInt16(kVK_F17)), (18, UInt16(kVK_F18)),
            (19, UInt16(kVK_F19)), (20, UInt16(kVK_F20)),
        ]
        for (number, code) in functionKeys { labels[code] = "F\(number)" }
        return labels
    }()
}
