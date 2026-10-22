/// Recovery state for an independently persisted workspace icon.
public enum WorkspaceIconCustomizationField: Codable, Equatable, Sendable {
    /// No icon mutation was recorded; the session snapshot remains authoritative.
    case absent
    /// The user selected this normalized thumbnail.
    case value(WorkspaceIcon)
    /// The user removed the icon, overriding older session snapshots.
    case cleared
}
