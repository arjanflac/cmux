/// One independently persisted workspace customization field.
///
/// `absent` means the recovery journal has never observed a mutation for the
/// field, while `cleared` is an explicit tombstone that prevents a stale
/// session snapshot from resurrecting an older value.
public enum WorkspaceCustomizationField: Codable, Equatable, Sendable {
    /// The field has no recovery-journal entry, so the session snapshot wins.
    case absent
    /// The most recent user mutation assigned the associated value.
    case value(String)
    /// The most recent user mutation explicitly cleared the field.
    case cleared
}

/// User-owned workspace identity persisted independently of session autosave.
///
/// Records are keyed by `Workspace.stableId`. Title and color are independent
/// so mutating one field never makes the other field authoritative.
public struct WorkspaceCustomization: Codable, Equatable, Sendable {
    /// Recovery state for the user-owned workspace title.
    public let customTitle: WorkspaceCustomizationField

    /// Recovery state for the user-owned workspace accent color.
    public let customColor: WorkspaceCustomizationField

    /// Recovery state for the user-selected workspace thumbnail.
    public let customIcon: WorkspaceIconCustomizationField

    /// Creates a workspace customization recovery record.
    ///
    /// - Parameters:
    ///   - customTitle: Recovery state for the workspace title.
    ///   - customColor: Recovery state for the workspace accent color.
    ///   - customIcon: Recovery state for the workspace thumbnail.
    public init(
        customTitle: WorkspaceCustomizationField = .absent,
        customColor: WorkspaceCustomizationField = .absent,
        customIcon: WorkspaceIconCustomizationField = .absent
    ) {
        self.customTitle = customTitle
        self.customColor = customColor
        self.customIcon = customIcon
    }

    private enum CodingKeys: String, CodingKey {
        case customTitle, customColor, customIcon
    }

    /// Decodes old recovery records without treating a missing icon as a removal.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customTitle = try container.decode(WorkspaceCustomizationField.self, forKey: .customTitle)
        customColor = try container.decode(WorkspaceCustomizationField.self, forKey: .customColor)
        customIcon = try container.decodeIfPresent(WorkspaceIconCustomizationField.self, forKey: .customIcon) ?? .absent
    }
}
