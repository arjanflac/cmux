import Foundation

/// An explicitly requested child task, independent of terminal selection.
public struct AgentTaskRequest: Codable, Equatable, Sendable {
    /// The installed harness that performs the task.
    public enum Provider: String, Codable, Sendable { case codex, claude, opencode }
    /// Provider-native approval policy; unrestricted work must be explicitly requested.
    public enum PermissionMode: String, Codable, Sendable { case providerDefault, unrestricted }
    /// Whether completion remains reusable or retires after its parent acknowledges the result.
    public enum Lifecycle: String, Codable, Sendable { case persistent, oneShot }
    /// Whether the task receives a terminal tab or runs without a view.
    public enum Presentation: String, Codable, Sendable { case terminal, background }

    /// Installed harness to use.
    public var provider: Provider
    /// The requested work, retained only while admitting and presenting the task.
    public var prompt: String
    /// An existing target workspace; the coordinator never creates one.
    public var workspaceID: UUID
    /// Persisted workspace identity, independent of a runtime window/session.
    public var workspaceStableID: UUID?
    /// Absolute local directory used by both provider and terminal.
    public var workingDirectory: URL
    /// Optional provider model identifier.
    public var model: String?
    /// Optional provider reasoning effort.
    public var effort: String?
    /// Explicit policy for this managed worker; missing legacy values use provider defaults.
    public var permissionMode: PermissionMode?
    /// Terminal by default; background must be requested explicitly.
    public var presentation: Presentation
    /// Missing legacy values remain persistent; one-shot retirement never deletes provider history.
    public var lifecycle: Lifecycle?
    /// Optional managed parent for task relationships and cancellation.
    public var parentTaskID: UUID?

    /// Creates a task. Background execution must be explicitly selected.
    public init(provider: Provider, prompt: String, workspaceID: UUID, workingDirectory: URL,
                model: String? = nil, effort: String? = nil,
                presentation: Presentation = .terminal, parentTaskID: UUID? = nil, workspaceStableID: UUID? = nil,
                permissionMode: PermissionMode = .providerDefault, lifecycle: Lifecycle = .persistent) {
        self.provider = provider
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.workspaceStableID = workspaceStableID
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.lifecycle = lifecycle
        self.presentation = presentation
        self.parentTaskID = parentTaskID
    }
}
