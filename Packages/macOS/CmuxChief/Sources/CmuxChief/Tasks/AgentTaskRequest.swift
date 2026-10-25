import Foundation

/// An explicitly requested child task, independent of terminal selection.
public struct AgentTaskRequest: Codable, Equatable, Sendable {
    /// The installed harness that performs the task.
    public enum Provider: String, Codable, Sendable { case codex, claude }
    /// Whether the task receives a terminal tab or runs without a view.
    public enum Presentation: String, Codable, Sendable { case terminal, background }

    /// Installed harness to use.
    public var provider: Provider
    /// The requested work, retained only while admitting and presenting the task.
    public var prompt: String
    /// An existing target workspace; the coordinator never creates one.
    public var workspaceID: UUID
    /// Absolute local directory used by both provider and terminal.
    public var workingDirectory: URL
    /// Optional provider model identifier.
    public var model: String?
    /// Optional provider reasoning effort.
    public var effort: String?
    /// Terminal by default; background must be requested explicitly.
    public var presentation: Presentation
    /// Optional managed parent for task relationships and cancellation.
    public var parentTaskID: UUID?

    /// Creates a task. Background execution must be explicitly selected.
    public init(provider: Provider, prompt: String, workspaceID: UUID, workingDirectory: URL,
                model: String? = nil, effort: String? = nil,
                presentation: Presentation = .terminal, parentTaskID: UUID? = nil) {
        self.provider = provider
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.presentation = presentation
        self.parentTaskID = parentTaskID
    }
}
