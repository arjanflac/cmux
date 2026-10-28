import Foundation

/// Routes the existing controls to one canonical page only in personal hosts.
/// This changes presentation, never setting keys, stores, or their defaults.
enum PersonalSettingsRouting {
    static let relocated: [SettingsSectionID: Set<String>] = [
        .terminal: ["agent-orchestration", "codex-quiet", "agent-auto-resume", "agent-hibernation",
                    "agent-hibernation-idle", "agent-hibernation-max", "renderer-realization",
                    "renderer-realization-idle", "renderer-realization-max", "memory-guardrail",
                    "memory-guardrail-threshold"],
        .textBox: ["show-textbox-new-terminals", "focus-textbox-new-terminals"],
        .app: ["reorder-notification"],
        .betaFeatures: ["conversationSidebar"],
        .keyboardShortcuts: ["base-keymap"],
    ]

    static func destination(for entry: CuratedSettingEntry, available: Bool) -> SettingsSectionID {
        available && relocated[entry.section]?.contains(entry.id) == true ? .personal : entry.section
    }

    static func navigation(section: SettingsSectionID, anchorID: String, available: Bool) -> (section: SettingsSectionID, anchorID: String) {
        if section == .personal, !available { return (.app, "section:app") }
        guard available else { return (section, anchorID) }
        for (origin, identifiers) in relocated {
            let prefix = "setting:\(origin.rawValue):"
            if anchorID.hasPrefix(prefix), identifiers.contains(String(anchorID.dropFirst(prefix.count))) {
                return (.personal, "setting:personal:" + String(anchorID.dropFirst(prefix.count)))
            }
        }
        return (section, anchorID)
    }

    static func isVisible(_ section: SettingsSectionID, available: Bool) -> Bool {
        section != .personal || available
    }
}
