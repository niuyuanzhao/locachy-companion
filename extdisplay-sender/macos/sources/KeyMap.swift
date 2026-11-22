// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

enum HidKey: Equatable, Hashable {
    case modifier(UInt8)
    case keyboard(UInt16)
    case consumer(UInt16)
}

// Physical 1:1 translation from Linux input-event-codes.h (evdev) scancodes to:
// 1. USB HID Keyboard/Keypad (Usage Page 0x07) & Consumer (Usage Page 0x0C) usages
//    for the Karabiner DriverKit virtual USB keyboard path.
// 2. macOS hardware CGKeyCode (Carbon kVK_*) values plus implicit modifier flags
//    for the CGEvent fallback path so macOS applies its own active layout and IME.
enum KeyMap {
    // MARK: - Linux evdev -> USB HID

    private static let evdevToHid: [Int: HidKey] = [
        // Modifiers (USB HID Usage Page 0x07 modifier bitmap)
        29:  .modifier(0x01), // KEY_LEFTCTRL
        42:  .modifier(0x02), // KEY_LEFTSHIFT
        56:  .modifier(0x04), // KEY_LEFTALT
        125: .modifier(0x08), // KEY_LEFTMETA
        97:  .modifier(0x10), // KEY_RIGHTCTRL
        54:  .modifier(0x20), // KEY_RIGHTSHIFT
        100: .modifier(0x40), // KEY_RIGHTALT
        126: .modifier(0x80), // KEY_RIGHTMETA

        // Letters (A = 0x04 .. Z = 0x1D)
        30: .keyboard(0x04), // KEY_A
        48: .keyboard(0x05), // KEY_B
        46: .keyboard(0x06), // KEY_C
        32: .keyboard(0x07), // KEY_D
        18: .keyboard(0x08), // KEY_E
        33: .keyboard(0x09), // KEY_F
        34: .keyboard(0x0A), // KEY_G
        35: .keyboard(0x0B), // KEY_H
        23: .keyboard(0x0C), // KEY_I
        36: .keyboard(0x0D), // KEY_J
        37: .keyboard(0x0E), // KEY_K
        38: .keyboard(0x0F), // KEY_L
        50: .keyboard(0x10), // KEY_M
        49: .keyboard(0x11), // KEY_N
        24: .keyboard(0x12), // KEY_O
        25: .keyboard(0x13), // KEY_P
        16: .keyboard(0x14), // KEY_Q
        19: .keyboard(0x15), // KEY_R
        31: .keyboard(0x16), // KEY_S
        20: .keyboard(0x17), // KEY_T
        22: .keyboard(0x18), // KEY_U
        47: .keyboard(0x19), // KEY_V
        17: .keyboard(0x1A), // KEY_W
        45: .keyboard(0x1B), // KEY_X
        21: .keyboard(0x1C), // KEY_Y
        44: .keyboard(0x1D), // KEY_Z

        // Number row (1 = 0x1E .. 0 = 0x27)
        2:  .keyboard(0x1E), // KEY_1
        3:  .keyboard(0x1F), // KEY_2
        4:  .keyboard(0x20), // KEY_3
        5:  .keyboard(0x21), // KEY_4
        6:  .keyboard(0x22), // KEY_5
        7:  .keyboard(0x23), // KEY_6
        8:  .keyboard(0x24), // KEY_7
        9:  .keyboard(0x25), // KEY_8
        10: .keyboard(0x26), // KEY_9
        11: .keyboard(0x27), // KEY_0

        // Control / whitespace / punctuation
        28: .keyboard(0x28), // KEY_ENTER
        1:  .keyboard(0x29), // KEY_ESC
        14: .keyboard(0x2A), // KEY_BACKSPACE
        15: .keyboard(0x2B), // KEY_TAB
        57: .keyboard(0x2C), // KEY_SPACE
        12: .keyboard(0x2D), // KEY_MINUS
        13: .keyboard(0x2E), // KEY_EQUAL
        26: .keyboard(0x2F), // KEY_LEFTBRACE
        27: .keyboard(0x30), // KEY_RIGHTBRACE
        43: .keyboard(0x31), // KEY_BACKSLASH
        39: .keyboard(0x33), // KEY_SEMICOLON
        40: .keyboard(0x34), // KEY_APOSTROPHE
        41: .keyboard(0x35), // KEY_GRAVE
        51: .keyboard(0x36), // KEY_COMMA
        52: .keyboard(0x37), // KEY_DOT
        53: .keyboard(0x38), // KEY_SLASH
        58: .keyboard(0x39), // KEY_CAPSLOCK

        // Function keys F1..F12 (0x3A..0x45)
        59: .keyboard(0x3A), // KEY_F1
        60: .keyboard(0x3B), // KEY_F2
        61: .keyboard(0x3C), // KEY_F3
        62: .keyboard(0x3D), // KEY_F4
        63: .keyboard(0x3E), // KEY_F5
        64: .keyboard(0x3F), // KEY_F6
        65: .keyboard(0x40), // KEY_F7
        66: .keyboard(0x41), // KEY_F8
        67: .keyboard(0x42), // KEY_F9
        68: .keyboard(0x43), // KEY_F10
        87: .keyboard(0x44), // KEY_F11
        88: .keyboard(0x45), // KEY_F12

        // System / navigation / arrows (0x46..0x52)
        99:  .keyboard(0x46), // KEY_SYSRQ (PrintScreen)
        70:  .keyboard(0x47), // KEY_SCROLLLOCK
        119: .keyboard(0x48), // KEY_PAUSE
        110: .keyboard(0x49), // KEY_INSERT
        102: .keyboard(0x4A), // KEY_HOME
        104: .keyboard(0x4B), // KEY_PAGEUP
        111: .keyboard(0x4C), // KEY_DELETE
        107: .keyboard(0x4D), // KEY_END
        109: .keyboard(0x4E), // KEY_PAGEDOWN
        106: .keyboard(0x4F), // KEY_RIGHT
        105: .keyboard(0x50), // KEY_LEFT
        108: .keyboard(0x51), // KEY_DOWN
        103: .keyboard(0x52), // KEY_UP

        // Keypad (0x53..0x63, 0x67, 0x85)
        69:  .keyboard(0x53), // KEY_NUMLOCK
        98:  .keyboard(0x54), // KEY_KPSLASH
        55:  .keyboard(0x55), // KEY_KPASTERISK
        74:  .keyboard(0x56), // KEY_KPMINUS
        78:  .keyboard(0x57), // KEY_KPPLUS
        96:  .keyboard(0x58), // KEY_KPENTER
        79:  .keyboard(0x59), // KEY_KP1
        80:  .keyboard(0x5A), // KEY_KP2
        81:  .keyboard(0x5B), // KEY_KP3
        75:  .keyboard(0x5C), // KEY_KP4
        76:  .keyboard(0x5D), // KEY_KP5
        77:  .keyboard(0x5E), // KEY_KP6
        71:  .keyboard(0x5F), // KEY_KP7
        72:  .keyboard(0x60), // KEY_KP8
        73:  .keyboard(0x61), // KEY_KP9
        82:  .keyboard(0x62), // KEY_KP0
        83:  .keyboard(0x63), // KEY_KPDOT
        117: .keyboard(0x67), // KEY_KPEQUAL
        121: .keyboard(0x85), // KEY_KPCOMMA

        // ISO / Application
        86:  .keyboard(0x64), // KEY_102ND
        127: .keyboard(0x65), // KEY_COMPOSE (Application)
        139: .keyboard(0x65), // KEY_MENU (Application)

        // Extended function keys F13..F24 (0x68..0x73)
        183: .keyboard(0x68), // KEY_F13
        184: .keyboard(0x69), // KEY_F14
        185: .keyboard(0x6A), // KEY_F15
        186: .keyboard(0x6B), // KEY_F16
        187: .keyboard(0x6C), // KEY_F17
        188: .keyboard(0x6D), // KEY_F18
        189: .keyboard(0x6E), // KEY_F19
        190: .keyboard(0x6F), // KEY_F20
        191: .keyboard(0x70), // KEY_F21
        192: .keyboard(0x71), // KEY_F22
        193: .keyboard(0x72), // KEY_F23
        194: .keyboard(0x73), // KEY_F24

        // International / JIS / Korean keys
        85:  .keyboard(0x35), // KEY_ZENKAKUHANKAKU (Grave/Tilde)
        89:  .keyboard(0x87), // KEY_RO (International1)
        90:  .keyboard(0x88), // KEY_KATAKANA (International2)
        91:  .keyboard(0x88), // KEY_HIRAGANA (International2)
        93:  .keyboard(0x88), // KEY_KATAKANAHIRAGANA (International2)
        124: .keyboard(0x89), // KEY_YEN (International3)
        92:  .keyboard(0x8A), // KEY_HENKAN (International4)
        94:  .keyboard(0x8B), // KEY_MUHENKAN (International5)
        122: .keyboard(0x90), // KEY_HANGEUL (LANG1)
        123: .keyboard(0x91), // KEY_HANJA (LANG2)

        // Consumer Control (USB HID Usage Page 0x0C)
        113: .consumer(0xE2), // KEY_MUTE
        114: .consumer(0xEA), // KEY_VOLUMEDOWN
        115: .consumer(0xE9), // KEY_VOLUMEUP
        163: .consumer(0xB5), // KEY_NEXTSONG
        164: .consumer(0xCD), // KEY_PLAYPAUSE
        165: .consumer(0xB6), // KEY_PREVIOUSSONG
        166: .consumer(0xB7), // KEY_STOPCD
        224: .consumer(0x70), // KEY_BRIGHTNESSDOWN
        225: .consumer(0x6F), // KEY_BRIGHTNESSUP
    ]

    static func hidKey(forEvdev code: Int) -> HidKey? {
        evdevToHid[code]
    }

    // MARK: - Linux evdev -> macOS Carbon hardware CGKeyCode

    private static let evdevToMacKeyCode: [Int: CGKeyCode] = [
        // ANSI letters
        30: 0,  // KEY_A -> kVK_ANSI_A
        31: 1,  // KEY_S -> kVK_ANSI_S
        32: 2,  // KEY_D -> kVK_ANSI_D
        33: 3,  // KEY_F -> kVK_ANSI_F
        35: 4,  // KEY_H -> kVK_ANSI_H
        34: 5,  // KEY_G -> kVK_ANSI_G
        44: 6,  // KEY_Z -> kVK_ANSI_Z
        45: 7,  // KEY_X -> kVK_ANSI_X
        46: 8,  // KEY_C -> kVK_ANSI_C
        47: 9,  // KEY_V -> kVK_ANSI_V
        48: 11, // KEY_B -> kVK_ANSI_B
        16: 12, // KEY_Q -> kVK_ANSI_Q
        17: 13, // KEY_W -> kVK_ANSI_W
        18: 14, // KEY_E -> kVK_ANSI_E
        19: 15, // KEY_R -> kVK_ANSI_R
        21: 16, // KEY_Y -> kVK_ANSI_Y
        20: 17, // KEY_T -> kVK_ANSI_T
        24: 31, // KEY_O -> kVK_ANSI_O
        22: 32, // KEY_U -> kVK_ANSI_U
        23: 34, // KEY_I -> kVK_ANSI_I
        25: 35, // KEY_P -> kVK_ANSI_P
        38: 37, // KEY_L -> kVK_ANSI_L
        36: 38, // KEY_J -> kVK_ANSI_J
        37: 40, // KEY_K -> kVK_ANSI_K
        49: 45, // KEY_N -> kVK_ANSI_N
        50: 46, // KEY_M -> kVK_ANSI_M

        // ANSI number row & punctuation
        2:  18, // KEY_1 -> kVK_ANSI_1
        3:  19, // KEY_2 -> kVK_ANSI_2
        4:  20, // KEY_3 -> kVK_ANSI_3
        5:  21, // KEY_4 -> kVK_ANSI_4
        7:  22, // KEY_6 -> kVK_ANSI_6
        6:  23, // KEY_5 -> kVK_ANSI_5
        13: 24, // KEY_EQUAL -> kVK_ANSI_Equal
        10: 25, // KEY_9 -> kVK_ANSI_9
        8:  26, // KEY_7 -> kVK_ANSI_7
        12: 27, // KEY_MINUS -> kVK_ANSI_Minus
        9:  28, // KEY_8 -> kVK_ANSI_8
        11: 29, // KEY_0 -> kVK_ANSI_0
        27: 30, // KEY_RIGHTBRACE -> kVK_ANSI_RightBracket
        26: 33, // KEY_LEFTBRACE -> kVK_ANSI_LeftBracket
        40: 39, // KEY_APOSTROPHE -> kVK_ANSI_Quote
        39: 41, // KEY_SEMICOLON -> kVK_ANSI_Semicolon
        43: 42, // KEY_BACKSLASH -> kVK_ANSI_Backslash
        51: 43, // KEY_COMMA -> kVK_ANSI_Comma
        53: 44, // KEY_SLASH -> kVK_ANSI_Slash
        52: 47, // KEY_DOT -> kVK_ANSI_Period
        41: 50, // KEY_GRAVE -> kVK_ANSI_Grave

        // Control / whitespace
        28: 36, // KEY_ENTER -> kVK_Return
        15: 48, // KEY_TAB -> kVK_Tab
        57: 49, // KEY_SPACE -> kVK_Space
        14: 51, // KEY_BACKSPACE -> kVK_Delete
        1:  53, // KEY_ESC -> kVK_Escape

        // Modifiers & Caps Lock
        126: 54, // KEY_RIGHTMETA -> kVK_RightCommand
        125: 55, // KEY_LEFTMETA -> kVK_Command
        42:  56, // KEY_LEFTSHIFT -> kVK_Shift
        58:  57, // KEY_CAPSLOCK -> kVK_CapsLock
        56:  58, // KEY_LEFTALT -> kVK_Option
        29:  59, // KEY_LEFTCTRL -> kVK_Control
        54:  60, // KEY_RIGHTSHIFT -> kVK_RightShift
        100: 61, // KEY_RIGHTALT -> kVK_RightOption
        97:  62, // KEY_RIGHTCTRL -> kVK_RightControl

        // Arrows
        105: 123, // KEY_LEFT -> kVK_LeftArrow
        106: 124, // KEY_RIGHT -> kVK_RightArrow
        108: 125, // KEY_DOWN -> kVK_DownArrow
        103: 126, // KEY_UP -> kVK_UpArrow

        // Navigation
        110: 114, // KEY_INSERT -> kVK_Help
        102: 115, // KEY_HOME -> kVK_Home
        104: 116, // KEY_PAGEUP -> kVK_PageUp
        111: 117, // KEY_DELETE -> kVK_ForwardDelete
        107: 119, // KEY_END -> kVK_End
        109: 121, // KEY_PAGEDOWN -> kVK_PageDown

        // Function keys F1..F20
        59:  122, // KEY_F1 -> kVK_F1
        60:  120, // KEY_F2 -> kVK_F2
        61:  99,  // KEY_F3 -> kVK_F3
        62:  118, // KEY_F4 -> kVK_F4
        63:  96,  // KEY_F5 -> kVK_F5
        64:  97,  // KEY_F6 -> kVK_F6
        65:  98,  // KEY_F7 -> kVK_F7
        66:  100, // KEY_F8 -> kVK_F8
        67:  101, // KEY_F9 -> kVK_F9
        68:  109, // KEY_F10 -> kVK_F10
        87:  103, // KEY_F11 -> kVK_F11
        88:  111, // KEY_F12 -> kVK_F12
        183: 105, // KEY_F13 -> kVK_F13
        184: 107, // KEY_F14 -> kVK_F14
        185: 113, // KEY_F15 -> kVK_F15
        186: 106, // KEY_F16 -> kVK_F16
        187: 64,  // KEY_F17 -> kVK_F17
        188: 79,  // KEY_F18 -> kVK_F18
        189: 80,  // KEY_F19 -> kVK_F19
        190: 90,  // KEY_F20 -> kVK_F20

        // Numpad
        83:  65, // KEY_KPDOT -> kVK_ANSI_KeypadDecimal
        55:  67, // KEY_KPASTERISK -> kVK_ANSI_KeypadMultiply
        78:  69, // KEY_KPPLUS -> kVK_ANSI_KeypadPlus
        69:  71, // KEY_NUMLOCK -> kVK_ANSI_KeypadClear
        98:  75, // KEY_KPSLASH -> kVK_ANSI_KeypadDivide
        96:  76, // KEY_KPENTER -> kVK_ANSI_KeypadEnter
        74:  78, // KEY_KPMINUS -> kVK_ANSI_KeypadMinus
        117: 81, // KEY_KPEQUAL -> kVK_ANSI_KeypadEquals
        82:  82, // KEY_KP0 -> kVK_ANSI_Keypad0
        79:  83, // KEY_KP1 -> kVK_ANSI_Keypad1
        80:  84, // KEY_KP2 -> kVK_ANSI_Keypad2
        81:  85, // KEY_KP3 -> kVK_ANSI_Keypad3
        75:  86, // KEY_KP4 -> kVK_ANSI_Keypad4
        76:  87, // KEY_KP5 -> kVK_ANSI_Keypad5
        77:  88, // KEY_KP6 -> kVK_ANSI_Keypad6
        71:  89, // KEY_KP7 -> kVK_ANSI_Keypad7
        72:  91, // KEY_KP8 -> kVK_ANSI_Keypad8
        73:  92, // KEY_KP9 -> kVK_ANSI_Keypad9
        121: 95, // KEY_KPCOMMA -> kVK_JIS_KeypadComma

        // ISO & JIS / Korean / Laptop keys
        85:  50,  // KEY_ZENKAKUHANKAKU -> kVK_ANSI_Grave
        86:  10,  // KEY_102ND -> kVK_ISO_Section
        90:  104, // KEY_KATAKANA -> kVK_JIS_Kana
        91:  104, // KEY_HIRAGANA -> kVK_JIS_Kana
        93:  104, // KEY_KATAKANAHIRAGANA -> kVK_JIS_Kana
        127: 110, // KEY_COMPOSE -> kVK_ContextualMenu
        139: 110, // KEY_MENU -> kVK_ContextualMenu
        143: 63,  // KEY_WAKEUP (laptop Fn) -> kVK_Function
        124: 93,  // KEY_YEN -> kVK_JIS_Yen
        89:  94,  // KEY_RO -> kVK_JIS_Underscore
        94:  102, // KEY_MUHENKAN -> kVK_JIS_Eisu
        92:  104, // KEY_HENKAN -> kVK_JIS_Kana
        122: 104, // KEY_HANGEUL -> kVK_JIS_Kana
        123: 102, // KEY_HANJA -> kVK_JIS_Eisu
    ]

    static func macKeyCode(forEvdev code: Int) -> CGKeyCode? {
        evdevToMacKeyCode[code]
    }

    static func modifierFlag(forMacKeyCode code: CGKeyCode) -> CGEventFlags {
        switch code {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        default: return []
        }
    }

    private static let secondaryFnKeyCodes: Set<CGKeyCode> = [
        // Arrow keys
        123, 124, 125, 126,
        // Navigation keys
        114, 115, 116, 117, 119, 121,
        // F1..F20
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static let numericPadKeyCodes: Set<CGKeyCode> = [
        // Arrow keys
        123, 124, 125, 126,
        // Keypad keys
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ]

    static func implicitKeyFlags(forMacKeyCode code: CGKeyCode) -> CGEventFlags {
        var flags: CGEventFlags = []
        if secondaryFnKeyCodes.contains(code) { flags.insert(.maskSecondaryFn) }
        if numericPadKeyCodes.contains(code) { flags.insert(.maskNumericPad) }
        return flags
    }
}
