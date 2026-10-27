/// Immutable limits shared by every grant and pending child in one task lineage.
///
/// Reservations count existing and pending tasks, survive capability reissuance
/// and revocation, and never refill on completion. The app scheduler separately
/// owns active-worker capacity, durable schedule grants, and paid-turn budgets.
public struct AgentTaskScopeBudget: Sendable, Codable, Equatable {
    /// Maximum child depth, with the root at zero; valid values are zero through four.
    public let maxDepth: Int
    /// Maximum existing plus pending direct children per owner; at most eight.
    public let maxChildrenPerOwner: Int
    /// Maximum descendants reserved across all branches of the root; at most 4,680.
    public let maxDescendants: Int

    /// Describes limits that the authority validates before issuing a grant.
    ///
    /// - Parameters:
    ///   - maxDepth: Maximum delegation depth; defaults to four.
    ///   - maxChildrenPerOwner: Direct-child limit; defaults to eight.
    ///   - maxDescendants: Nonreplenishing root reservation budget; defaults to 64.
    public init(maxDepth: Int = 4, maxChildrenPerOwner: Int = 8, maxDescendants: Int = 64) {
        self.maxDepth = maxDepth
        self.maxChildrenPerOwner = maxChildrenPerOwner
        self.maxDescendants = maxDescendants
    }

    var isValid: Bool {
        (0...4).contains(maxDepth) && (0...8).contains(maxChildrenPerOwner)
            && (0...4_680).contains(maxDescendants)
    }
}
