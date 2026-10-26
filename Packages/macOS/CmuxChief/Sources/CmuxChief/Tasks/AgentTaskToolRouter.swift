import Foundation

/// A single injected route from provider tools to the app-owned coordinator.
public actor AgentTaskToolRouter {
    /// The app-authenticated handler; returned JSON is data, never executable text.
    public typealias Handler = @Sendable (AgentTaskToolCall) async throws -> Data
    private var handler: Handler?
    private var enabled: (@Sendable () async -> Bool)?
    /// Creates an inert router; no tool is advertised before app composition installs it.
    public init() {}
    /// Installs the app's explicit policy and control handler.
    /// - Parameters:
    ///   - enabled: Live user setting; no environment variable grants permission.
    ///   - handler: Composition-root control path.
    public func install(enabled: @escaping @Sendable () async -> Bool, handler: @escaping Handler) {
        self.enabled = enabled; self.handler = handler
    }
    /// Whether newly created managed threads may advertise the tool.
    public func isEnabled() async -> Bool { await enabled?() == true && handler != nil }
    /// Executes a provider-authenticated request without retrying it.
    /// - Parameter call: Live provider identity and argument bytes.
    /// - Returns: Bounded coordinator reply, including its response-ownership disposition.
    /// - Throws: Missing composition or handler failure. Installed brokers return owned policy errors.
    public func call(_ call: AgentTaskToolCall) async throws -> Data {
        // Previously advertised tools can outlive a setting change. The authenticated
        // broker must own and return their disabled-policy answer, without executing.
        guard let handler else { throw AgentManagedTaskError.unsupported("orchestration_disabled") }
        return try await handler(call)
    }
}
