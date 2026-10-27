/// App-owned active-turn limits, independent of each provider's native subagent settings.
///
/// A starting, attention, or disconnected worker occupies capacity until a confirmed
/// terminal receipt. Idle conversations do not. Zero disables admissions for that lane.
public struct AgentTaskExecutionLimits: Equatable, Sendable {
    /// Maximum simultaneous managed worker turns across providers.
    public let total: UInt8
    /// Maximum simultaneous Codex worker turns.
    public let codex: UInt8
    /// Maximum simultaneous Claude worker turns.
    public let claude: UInt8
    /// Maximum simultaneous OpenCode worker turns.
    public let opencode: UInt8

    /// Creates immutable limits for a coordinator instance.
    /// - Parameters:
    ///   - total: Overall cap; defaults to six.
    ///   - codex: Codex cap; defaults to four.
    ///   - claude: Claude cap; defaults to two.
    ///   - opencode: OpenCode cap; defaults to two.
    public init(total: UInt8 = 6, codex: UInt8 = 4, claude: UInt8 = 2, opencode: UInt8 = 2) {
        self.total = total; self.codex = codex; self.claude = claude; self.opencode = opencode
    }

    func capacity(for provider: AgentTaskRequest.Provider) -> Int {
        switch provider {
        case .codex: return Int(codex)
        case .claude: return Int(claude)
        case .opencode: return Int(opencode)
        }
    }
}
