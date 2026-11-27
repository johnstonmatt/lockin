import SwiftUI
import AppKit
import LockInCore

let accent = Color(red: 0.25, green: 0.68, blue: 0.53)

// Validated (dataviz validate_palette.js) against white and #1e1e1e card surfaces, all pairs.
extension WorkPhase {
    var color: Color {
        switch self {
        case .work: return Color(light: 0x1baf7a, dark: 0x199e70)
        case .overtime: return Color(light: 0x8b5cf6, dark: 0x9d74f7)
        case .break: return Color(light: 0x2a78d6, dark: 0x3987e5)
        case .pause: return Color(light: 0xeb6834, dark: 0xd95926)
        }
    }
    var label: String {
        switch self {
        case .work: return "Work"
        case .overtime: return "Overtime"
        case .break: return "Break"
        case .pause: return "Pause"
        }
    }

    // Wording for the running session's phase; nil is no session.

    /// The main window's title bar status.
    static func status(_ phase: WorkPhase?) -> String {
        switch phase {
        case .work: return "Focusing"
        case .overtime: return "In overtime"
        case .break: return "On a break"
        case .pause: return "Paused"
        case nil: return "Your time, protected"
        }
    }
    /// The Focus page's heading.
    static func heading(_ phase: WorkPhase?) -> String {
        switch phase {
        case .work, nil: return "Time to work"
        case .overtime: return "Overtime"
        case .break: return "Earned break"
        case .pause: return "Paused"
        }
    }
    /// The menu bar panel's caption.
    static func caption(_ phase: WorkPhase?) -> String {
        switch phase {
        case .pause: return "Paused · your reason is recorded"
        case .break: return "Enjoy your earned break."
        case .overtime: return "Overtime · target reached"
        case .work, nil: return "A little space for your best work."
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}
