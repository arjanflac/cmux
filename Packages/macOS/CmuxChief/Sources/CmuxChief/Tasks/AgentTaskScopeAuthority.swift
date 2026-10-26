import CryptoKit
import Foundation

/// Owns ephemeral, session-bound task capabilities and bounded child reservations.
///
/// This actor performs no process, environment, filesystem, provider, or UI lookup.
/// Only the trusted app composition root may issue grants, after proving a live
/// process and selected chat, or an app-owned native worker thread. Session IDs
/// must identify the provider connection as well as the exact thread where needed.
/// A workspace ID, cwd, title, socket credential, or inherited `CMUX_*` dictionary
/// is never sufficient enrollment evidence.
///
/// External bridge calls use ``validate(token:callerSessionID:bindingGeneration:operation:targetTaskID:parentTaskID:)``
/// after the bridge's socket/process authorization. Native dynamic tools use
/// ``authorizeTrustedOwner(ownerTaskID:callerSessionID:bindingGeneration:operation:targetTaskID:parentTaskID:)``
/// only after binding and deduplicating the actual provider thread/turn/call IDs.
/// Neither public metadata nor a caller-supplied owner ID is an external credential.
/// This prevents confused-client authority; hostile same-UID code is out of scope.
///
/// ```swift
/// let authority = AgentTaskScopeAuthority() // One per app lifetime.
/// // Only after the composition root verifies the process and selected chat:
/// let capability = try await authority.issue(
///     ownerTaskID: taskID, providerSessionID: verifiedSessionID,
///     workspaceStableID: workspaceID, bindingGeneration: verifiedGeneration,
///     allowedOperations: [.status, .read, .createChild], allowedTargets: [],
///     lifetime: 300
/// )
/// let scope = try await authority.validate(
///     token: capability.token, callerSessionID: verifiedSessionID,
///     bindingGeneration: verifiedGeneration, operation: .createChild
/// )
/// // Reserve before dispatch; retain the slot if launch/acceptance is uncertain.
/// _ = try await authority.allowChild(owner: scope, newChildID: childID)
/// ```
public actor AgentTaskScopeAuthority {
    /// The app-lifetime epoch included in every token and scope.
    public nonisolated let epoch: UUID

    private let clock: @Sendable () async -> Date
    private let tokenEntropy: @Sendable () throws -> [UInt8]
    private var registry: [String: AgentTaskScope] = [:]
    private var revoked: Set<String> = []
    private var expired: Set<String> = []
    private var nodes: [UUID: AgentTaskScopeNode] = [:]
    private var latestInstant: Date?

    /// Constructs an empty registry with injected app epoch, clock, and token entropy.
    ///
    /// - Parameters:
    ///   - epoch: Fresh app-lifetime epoch; defaults to a new UUID. Never restore it from a schedule.
    ///   - clock: Clock seam, defaulting to wall time. Observed time never moves backward.
    ///   - tokenEntropy: Exactly 32 cryptographically random bytes per issue. The default uses
    ///     `SystemRandomNumberGenerator`; deterministic sources are for fixtures only.
    public init(epoch: UUID = UUID(), clock: @escaping @Sendable () async -> Date = { Date() },
                tokenEntropy: @escaping @Sendable () throws -> [UInt8] = {
                    var generator = SystemRandomNumberGenerator()
                    return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
                }) {
        self.epoch = epoch
        self.clock = clock
        self.tokenEntropy = tokenEntropy
    }

    /// Issues a grant after trusted native enrollment, returning its raw token once.
    ///
    /// Trusted composition only: callers supply already-proven identities and target
    /// ownership. Unknown initial targets are registered as existing direct children,
    /// consuming the same slots as pending children. Known targets must be descendants.
    /// Register ancestors before deeper descendants to preserve their actual hierarchy.
    /// The owner's own ID is always included. This method never interprets environment.
    ///
    /// A changed session, workspace, or binding generation revokes all previous grants
    /// for this owner and its descendants. Reissuing cannot reset graph budgets. A
    /// child must already be reserved and cannot exceed a live parent's operations or
    /// expiry. A status-only view is issued with `allowedOperations: [.status]`.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Exact enrolled task identity.
    ///   - providerSessionID: Verified provider connection/session identity.
    ///   - workspaceStableID: Explicit routing workspace, never enrollment proof.
    ///   - bindingGeneration: Verified process/chat binding generation.
    ///   - allowedOperations: Operations explicitly approved for this grant.
    ///   - allowedTargets: Verified existing children or already-registered descendants.
    ///   - lifetime: Positive finite lifetime in seconds.
    ///   - parentTaskID: Reserved graph parent for a child, otherwise nil.
    ///   - budget: Root limits for a new lineage; nil inherits existing limits or the defaults.
    /// - Returns: A non-Codable issued grant and safe scope/capability metadata.
    /// - Throws: ``AgentTaskScopeError`` for invalid enrollment inputs or exhausted limits,
    ///   or an injected entropy-source error. Failed issuance grants no authority.
    public func issue(ownerTaskID: UUID, providerSessionID: String, workspaceStableID: UUID,
                      bindingGeneration: String, allowedOperations: Set<AgentTaskScopeOperation>,
                      allowedTargets: Set<UUID>, lifetime: TimeInterval, parentTaskID: UUID? = nil,
                      budget: AgentTaskScopeBudget? = nil) async throws -> AgentTaskScopeGrant {
        let now = try observe(await clock())
        let expiresAt = now.addingTimeInterval(lifetime)
        guard lifetime.isFinite, lifetime > 0, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > now else { throw AgentTaskScopeError.invalidLifetime }
        guard !providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bindingGeneration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskScopeError.invalidBinding
        }

        var proposed = nodes
        if let node = proposed[ownerTaskID] {
            guard node.parentTaskID == parentTaskID else { throw AgentTaskScopeError.conflictingParent }
            guard budget == nil || budget == node.budget else { throw AgentTaskScopeError.invalidBudget }
        } else {
            guard parentTaskID == nil else { throw AgentTaskScopeError.missingParentGrant }
            let limits = budget ?? AgentTaskScopeBudget()
            guard limits.isValid else { throw AgentTaskScopeError.invalidBudget }
            proposed[ownerTaskID] = AgentTaskScopeNode(parentTaskID: nil, rootTaskID: ownerTaskID,
                                                      depth: 0, budget: limits)
        }
        guard let node = proposed[ownerTaskID] else { throw AgentTaskScopeError.missingParentGrant }
        if let parentTaskID {
            let parents = registry.values.filter { $0.ownerTaskID == parentTaskID }
            guard parents.contains(where: {
                $0.expiresAt > now && !expired.contains($0.tokenDigest)
                    && $0.allowedTargets.contains(ownerTaskID)
                    && allowedOperations.isSubset(of: $0.allowedOperations)
                    && $0.allowedOperations.contains(.createChild) && expiresAt <= $0.expiresAt
            }) else { throw AgentTaskScopeError.missingParentGrant }
        }
        for target in allowedTargets where target != ownerTaskID {
            if proposed[target] == nil {
                try reserveChild(ownerTaskID: ownerTaskID, newChildID: target, graph: &proposed)
            } else if !isDescendant(target, of: ownerTaskID, graph: proposed) {
                throw AgentTaskScopeError.targetNotOwned
            }
        }

        let bytes = try tokenEntropy()
        guard bytes.count == 32 else { throw AgentTaskScopeError.invalidEntropy }
        let token = "ats1_\(epoch.uuidString.lowercased())_\(hex(bytes))"
        let digest = tokenDigest(token)
        guard registry[digest] == nil, !revoked.contains(digest), !expired.contains(digest) else {
            throw AgentTaskScopeError.invalidEntropy
        }
        let capability = AgentTaskScopeCapability(tokenDigest: digest, appEpoch: epoch, issuedAt: now, expiresAt: expiresAt)
        let scope = AgentTaskScope(capability: capability, ownerTaskID: ownerTaskID,
                                   providerSessionID: providerSessionID, workspaceStableID: workspaceStableID,
                                   bindingGeneration: bindingGeneration, allowedOperations: allowedOperations,
                                   allowedTargets: allowedTargets.union([ownerTaskID]), rootTaskID: node.rootTaskID,
                                   parentTaskID: node.parentTaskID, depth: node.depth, budget: node.budget)
        let bindingChanged = registry.values.contains {
            $0.ownerTaskID == ownerTaskID && ($0.providerSessionID != providerSessionID
                || $0.workspaceStableID != workspaceStableID || $0.bindingGeneration != bindingGeneration)
        }
        if bindingChanged { revokeOwner(ownerTaskID) }
        nodes = proposed
        registry[digest] = scope
        return AgentTaskScopeGrant(token: token, scope: scope)
    }

    /// Validates an external bearer against its exact session, binding, operation, and target.
    ///
    /// The bridge must independently authenticate live process/binding evidence.
    /// Status/list callers must filter returned records by the returned `allowedTargets`;
    /// nil target means the authenticated owner, never a workspace-wide wildcard.
    /// Validation does not reserve launch capacity: use ``allowChild(owner:newChildID:)``
    /// immediately before dispatching new work.
    ///
    /// - Parameters:
    ///   - token: Raw credential received through private transport.
    ///   - callerSessionID: Verified exact session; omission always fails, including reads.
    ///   - bindingGeneration: Verified current generation; omission always fails.
    ///   - operation: Requested operation.
    ///   - targetTaskID: Exact task target, or nil for the caller itself.
    ///   - parentTaskID: Optional request parent, which must equal the caller's owner ID.
    /// - Returns: Current registry scope, including subsequently reserved targets.
    /// - Throws: ``AgentTaskScopeError`` on any missing, stale, conflicting, or out-of-scope input.
    public func validate(token: String, callerSessionID: String?, bindingGeneration: String?,
                         operation: AgentTaskScopeOperation, targetTaskID: UUID? = nil,
                         parentTaskID: UUID? = nil) async throws -> AgentTaskScope {
        let now = try observe(await clock())
        try validateFormat(token)
        let digest = tokenDigest(token)
        let scope = try registered(digest, now: now)
        try check(scope, callerSessionID: callerSessionID, bindingGeneration: bindingGeneration,
                  operation: operation, targetTaskID: targetTaskID, parentTaskID: parentTaskID)
        return scope
    }

    /// Authorizes native dynamic-tool dispatch from an already verified provider context.
    ///
    /// **Trusted composition only.** Never expose this method as an owner-ID socket or
    /// CLI endpoint. The app must derive owner/session/generation from its verified
    /// provider thread registry, not from tool arguments, environment, cwd, or title.
    /// It still requires an active issued grant and grants no authority by itself.
    ///
    /// - Parameters:
    ///   - ownerTaskID: Owner resolved from the trusted provider context.
    ///   - callerSessionID: Exact verified provider session.
    ///   - bindingGeneration: Current app-owned binding generation.
    ///   - operation: Requested operation.
    ///   - targetTaskID: Exact target, defaulting to the resolved owner.
    ///   - parentTaskID: Optional supplied parent; must equal the resolved owner.
    /// - Returns: An active grant authorizing this operation and target.
    /// - Throws: ``AgentTaskScopeError`` if no issued grant authorizes the call.
    public func authorizeTrustedOwner(ownerTaskID: UUID, callerSessionID: String, bindingGeneration: String,
                                      operation: AgentTaskScopeOperation, targetTaskID: UUID? = nil,
                                      parentTaskID: UUID? = nil) async throws -> AgentTaskScope {
        let now = try observe(await clock())
        let candidates = registry.values.filter { $0.ownerTaskID == ownerTaskID }
            .sorted { $0.tokenDigest < $1.tokenDigest }
        guard !candidates.isEmpty else { throw AgentTaskScopeError.unknownCapability }
        var rejection = AgentTaskScopeError.unknownCapability
        for candidate in candidates {
            do {
                let scope = try registered(candidate.tokenDigest, now: now)
                try check(scope, callerSessionID: callerSessionID, bindingGeneration: bindingGeneration,
                          operation: operation, targetTaskID: targetTaskID, parentTaskID: parentTaskID)
                return scope
            } catch let error as AgentTaskScopeError {
                rejection = error
            }
        }
        throw rejection
    }

    /// Atomically reserves a pending child using an active parent grant's creation right.
    ///
    /// **Trusted composition only.** Pass a scope returned by validation or trusted
    /// dispatch in this invocation, never externally decoded metadata. The hash is a
    /// registry reference, not a bearer credential. The actor rechecks grant liveness
    /// after its injected clock returns, so revocation during validation fails closed.
    /// Reservations are idempotent for the same parent/child and count before launch.
    /// Ancestor grants already authorized for this parent also learn the new target.
    ///
    /// - Parameters:
    ///   - owner: Issued parent scope whose registry grant permits child creation.
    ///   - newChildID: App-selected unique task identity; cannot reparent an existing task.
    /// - Returns: Updated parent grant containing the reserved child target.
    /// - Throws: ``AgentTaskScopeError`` on revoked/stale grants or exhausted graph limits.
    public func allowChild(owner: AgentTaskScope, newChildID: UUID) async throws -> AgentTaskScope {
        let now = try observe(await clock())
        guard owner.appEpoch == epoch else { throw AgentTaskScopeError.epochMismatch }
        let scope = try registered(owner.tokenDigest, now: now)
        guard owner.ownerTaskID == scope.ownerTaskID else { throw AgentTaskScopeError.targetNotOwned }
        try check(scope, callerSessionID: owner.providerSessionID, bindingGeneration: owner.bindingGeneration,
                  operation: .createChild, targetTaskID: nil, parentTaskID: nil)
        try reserveChild(ownerTaskID: scope.ownerTaskID, newChildID: newChildID, graph: &nodes)
        for (digest, grant) in registry where grant.allowedTargets.contains(scope.ownerTaskID)
            && (grant.ownerTaskID == scope.ownerTaskID || isDescendant(scope.ownerTaskID, of: grant.ownerTaskID, graph: nodes)) {
            registry[digest]?.allowedTargets.insert(newChildID)
        }
        guard let updated = registry[scope.tokenDigest] else { throw AgentTaskScopeError.unknownCapability }
        return updated
    }

    /// Revokes every capability for an owner and its descendants without refunding slots.
    ///
    /// Trusted app lifecycle calls this on process exit, session switch, ownership
    /// transfer, or policy/setting changes. A later issue requires fresh live proof.
    /// - Parameter ownerTaskID: Owner whose authority and descendant grants must end.
    public func revokeOwner(_ ownerTaskID: UUID) {
        for (digest, scope) in registry where scope.ownerTaskID == ownerTaskID
            || isDescendant(scope.ownerTaskID, of: ownerTaskID, graph: nodes) {
            revoked.insert(digest)
            registry.removeValue(forKey: digest)
        }
    }

    /// Revokes all ephemeral capabilities, preserving nonreplenishing graph reservations.
    ///
    /// Trusted composition only. On app restart construct a new authority with a
    /// fresh epoch instead of restoring tokens. Persistent schedule grants are separate.
    public func revokeAll() {
        revoked.formUnion(registry.keys)
        registry.removeAll()
    }

    /// Clamps backward clock changes so expired grants cannot become live again.
    private func observe(_ instant: Date) throws -> Date {
        guard instant.timeIntervalSince1970.isFinite else { throw AgentTaskScopeError.invalidLifetime }
        let now = max(instant, latestInstant ?? instant)
        latestInstant = now
        return now
    }

    private func registered(_ digest: String, now: Date) throws -> AgentTaskScope {
        if revoked.contains(digest) { throw AgentTaskScopeError.revoked }
        if expired.contains(digest) { throw AgentTaskScopeError.expired }
        guard let scope = registry[digest] else { throw AgentTaskScopeError.unknownCapability }
        guard scope.appEpoch == epoch else { throw AgentTaskScopeError.epochMismatch }
        guard scope.expiresAt > now else {
            expired.insert(digest)
            throw AgentTaskScopeError.expired
        }
        return scope
    }

    private func check(_ scope: AgentTaskScope, callerSessionID: String?, bindingGeneration: String?,
                       operation: AgentTaskScopeOperation, targetTaskID: UUID?, parentTaskID: UUID?) throws {
        guard callerSessionID == scope.providerSessionID else { throw AgentTaskScopeError.sessionMismatch }
        guard bindingGeneration == scope.bindingGeneration else { throw AgentTaskScopeError.bindingMismatch }
        guard parentTaskID == nil || parentTaskID == scope.ownerTaskID else { throw AgentTaskScopeError.conflictingParent }
        guard scope.allowedOperations.contains(operation) else { throw AgentTaskScopeError.operationDenied }
        let target = targetTaskID ?? scope.ownerTaskID
        guard scope.allowedTargets.contains(target), operation != .createChild || target == scope.ownerTaskID else {
            throw AgentTaskScopeError.targetNotOwned
        }
    }

    private func reserveChild(ownerTaskID: UUID, newChildID: UUID,
                              graph: inout [UUID: AgentTaskScopeNode]) throws {
        guard let owner = graph[ownerTaskID] else { throw AgentTaskScopeError.missingParentGrant }
        if let existing = graph[newChildID] {
            guard existing.parentTaskID == ownerTaskID else { throw AgentTaskScopeError.targetNotOwned }
            return
        }
        guard owner.depth < owner.budget.maxDepth else { throw AgentTaskScopeError.depthLimitExceeded }
        guard owner.children.count < owner.budget.maxChildrenPerOwner else { throw AgentTaskScopeError.childLimitExceeded }
        let descendants = graph.values.filter { $0.rootTaskID == owner.rootTaskID && $0.parentTaskID != nil }.count
        guard descendants < owner.budget.maxDescendants else { throw AgentTaskScopeError.lineageBudgetExceeded }
        graph[newChildID] = AgentTaskScopeNode(parentTaskID: ownerTaskID, rootTaskID: owner.rootTaskID,
                                              depth: owner.depth + 1, budget: owner.budget)
        graph[ownerTaskID]?.children.insert(newChildID)
    }

    private func isDescendant(_ target: UUID, of owner: UUID, graph: [UUID: AgentTaskScopeNode]) -> Bool {
        var cursor = graph[target]?.parentTaskID
        while let parent = cursor {
            if parent == owner { return true }
            cursor = graph[parent]?.parentTaskID
        }
        return false
    }

    private func validateFormat(_ token: String) throws {
        guard token.utf8.count == 106 else { throw AgentTaskScopeError.malformedToken }
        let parts = token.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ats1", parts[1].count == 36,
              let tokenEpoch = UUID(uuidString: String(parts[1])),
              parts[1] == tokenEpoch.uuidString.lowercased(), parts[2].utf8.count == 64,
              parts[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AgentTaskScopeError.malformedToken
        }
        guard tokenEpoch == epoch else { throw AgentTaskScopeError.epochMismatch }
    }

    private func tokenDigest(_ token: String) -> String { hex(SHA256.hash(data: Data(token.utf8))) }

    private func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
