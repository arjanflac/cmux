import Foundation

/// A managed task's identity and last confirmed state.
public struct AgentTaskRecord: Codable, Equatable, Sendable {
    /// A disconnect is uncertainty, never successful completion.
    public enum Phase: String, Codable, Sendable {
        case starting, running, needsInput, completed, cancelled, failed, disconnected
        /// Whether a terminal receipt has been recorded.
        public var isFinished: Bool { self == .completed || self == .cancelled || self == .failed }
    }
    /// Stable coordinator task identity.
    public var id: UUID
    /// Harness executing this task.
    public var provider: AgentTaskRequest.Provider
    /// Requested existing workspace.
    public var workspaceID: UUID
    /// Persisted workspace identity, independent of a runtime window/session.
    public var workspaceStableID: UUID?
    /// Provider and terminal directory.
    public var workingDirectory: URL
    /// Whether this task requested a terminal.
    public var presentation: AgentTaskRequest.Presentation
    /// Managed parent, when supplied.
    public var parentTaskID: UUID?
    /// First prompt line used as a short terminal title.
    public var title: String
    /// Requested provider model.
    public var model: String?
    /// Requested provider reasoning effort, preserved across follow-up turns.
    public var effort: String?
    /// Explicit worker permissions, absent for legacy receipts and externally enrolled chats.
    public var permissionMode: AgentTaskRequest.PermissionMode?
    /// Whether this worker retires locally after its parent consumes a successful result.
    public var lifecycle: AgentTaskRequest.Lifecycle?
    /// Local retirement intent/receipt; absent for legacy and reusable conversations.
    public var retirement: AgentTaskRetirement?
    /// Most recently admitted operation; absent in legacy receipts.
    public var latestOperationID: UUID?
    /// Number of admitted turns; absent in legacy receipts.
    public var turnCount: Int?
    /// Exact provider identity, never inferred from terminal output.
    public var sessionID: String?
    /// Native terminal surface created for this task.
    public var surfaceID: UUID?
    /// Whether the worker is hidden from the active cmux list after local retirement.
    public var isRetired: Bool { retirement?.retiredAt != nil }
    /// Last reported task state.
    public var phase: Phase
    /// Latest turn result reported by the provider.
    public var result: String?
    /// Diagnostic or attention detail.
    public var detail: String?
    /// Task admission time.
    public var createdAt: Date
    /// Most recent receipt time.
    public var updatedAt: Date

    init(id: UUID, request: AgentTaskRequest, now: Date) {
        self.id = id
        provider = request.provider
        workspaceID = request.workspaceID
        workspaceStableID = request.workspaceStableID
        workingDirectory = request.workingDirectory
        presentation = request.presentation
        parentTaskID = request.parentTaskID
        title = String(request.prompt.split(separator: "\n").first.map(String.init)?.prefix(100) ?? "Task")
        model = request.model
        effort = request.effort
        permissionMode = request.permissionMode
        lifecycle = request.lifecycle
        latestOperationID = id
        turnCount = 1
        phase = .starting
        createdAt = now
        updatedAt = now
    }
}
