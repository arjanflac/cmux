import CryptoKit
import Foundation
import Testing
@testable import CmuxChief

struct AgentTaskScopeAuthorityTests {
    private let owner = UUID()
    private let workspace = UUID()
    private let session = "verified-provider-thread"
    private let generation = "live-process-and-chat-generation"

    private func authority(clock: AgentTaskScopeFixtureClock = AgentTaskScopeFixtureClock(),
                           epoch: UUID = UUID()) -> AgentTaskScopeAuthority {
        AgentTaskScopeAuthority(epoch: epoch, clock: { await clock.now() })
    }

    private func issue(_ authority: AgentTaskScopeAuthority,
                       operations: Set<AgentTaskScopeOperation> = Set(AgentTaskScopeOperation.allCases),
                       targets: Set<UUID> = [], lifetime: TimeInterval = 60,
                       budget: AgentTaskScopeBudget? = nil,
                       sessionID: String? = nil, binding: String? = nil) async throws -> AgentTaskScopeGrant {
        try await authority.issue(ownerTaskID: owner, providerSessionID: sessionID ?? session,
                                  workspaceStableID: workspace, bindingGeneration: binding ?? generation,
                                  allowedOperations: operations, allowedTargets: targets,
                                  lifetime: lifetime, budget: budget)
    }

    private func validate(_ authority: AgentTaskScopeAuthority, _ capability: AgentTaskScopeGrant,
                          operation: AgentTaskScopeOperation = .status,
                          target: UUID? = nil, parent: UUID? = nil) async throws -> AgentTaskScope {
        try await authority.validate(token: capability.token, callerSessionID: session,
                                     bindingGeneration: generation, operation: operation,
                                     targetTaskID: target, parentTaskID: parent)
    }

    @Test func bearerIsOpaqueAndOnlyPublicScopeMetadataEncodes() async throws {
        let authority = authority()
        let capability = try await issue(authority)
        #expect(try await validate(authority, capability) == capability.scope)
        let digest = SHA256.hash(data: Data(capability.token.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(capability.scope.tokenDigest == digest)
        let data = try JSONEncoder().encode(capability.scope)
        #expect(try JSONDecoder().decode(AgentTaskScope.self, from: data) == capability.scope)
        let metadata = try JSONEncoder().encode(capability.scope.capability)
        #expect(try JSONDecoder().decode(AgentTaskScopeCapability.self, from: metadata) == capability.scope.capability)
        #expect(!String(decoding: data, as: UTF8.self).contains(capability.token))
        #expect(!String(describing: capability).contains(capability.token))
        #expect(!String(reflecting: capability).contains(capability.token))
    }

    @Test(arguments: ["", "not-a-token", String(repeating: "a", count: 10_000)])
    func malformedTokensFailClosed(token: String) async {
        let authority = authority()
        await #expect(throws: AgentTaskScopeError.malformedToken) {
            try await authority.validate(token: token, callerSessionID: session,
                                         bindingGeneration: generation, operation: .status)
        }
    }

    @Test func unknownWellFormedTokenFailsClosed() async throws {
        let issuer = authority(), other = authority(epoch: issuer.epoch)
        let capability = try await issue(issuer)
        await #expect(throws: AgentTaskScopeError.unknownCapability) {
            try await validate(other, capability)
        }
    }

    @Test func expiryAndRevocationDoNotReviveAfterClockMovesBack() async throws {
        let clock = AgentTaskScopeFixtureClock(), authority = authority(clock: clock)
        let capability = try await issue(authority, lifetime: 10)
        await clock.advance(10)
        await #expect(throws: AgentTaskScopeError.expired) { try await validate(authority, capability) }
        await clock.advance(-20)
        await #expect(throws: AgentTaskScopeError.expired) { try await validate(authority, capability) }
        let fresh = try await issue(authority)
        await authority.revokeOwner(owner)
        await #expect(throws: AgentTaskScopeError.revoked) { try await validate(authority, fresh) }
    }

    @Test func allReadsRequireExactSessionAndGeneration() async throws {
        let authority = authority(), capability = try await issue(authority)
        for caller in [nil, "stale-thread"] as [String?] {
            await #expect(throws: AgentTaskScopeError.sessionMismatch) {
                try await authority.validate(token: capability.token, callerSessionID: caller,
                                             bindingGeneration: generation, operation: .status)
            }
        }
        for binding in [nil, "stale-generation"] as [String?] {
            await #expect(throws: AgentTaskScopeError.bindingMismatch) {
                try await authority.validate(token: capability.token, callerSessionID: session,
                                             bindingGeneration: binding, operation: .read)
            }
        }
    }

    @Test func aNewBindingRevokesEveryOldOwnerGrant() async throws {
        let authority = authority()
        let first = try await issue(authority)
        let reader = try await issue(authority, operations: [.status])
        let replacement = try await issue(authority, sessionID: "new-session", binding: "new-binding")
        for capability in [first, reader] {
            await #expect(throws: AgentTaskScopeError.revoked) { try await validate(authority, capability) }
        }
        #expect(try await authority.validate(token: replacement.token, callerSessionID: "new-session",
                                            bindingGeneration: "new-binding", operation: .status).ownerTaskID == owner)
    }

    @Test(arguments: ["session", "generation", "workspace"])
    func eachBindingComponentIndependentlyRevokesOldTokens(component: String) async throws {
        let authority = authority(), old = try await issue(authority)
        _ = try await authority.issue(ownerTaskID: owner,
                                      providerSessionID: component == "session" ? "replacement" : session,
                                      workspaceStableID: component == "workspace" ? UUID() : workspace,
                                      bindingGeneration: component == "generation" ? "replacement" : generation,
                                      allowedOperations: [.status], allowedTargets: [], lifetime: 60)
        await #expect(throws: AgentTaskScopeError.revoked) { try await validate(authority, old) }
    }

    @Test func conflictingParentAndUnownedTargetsFailClosed() async throws {
        let authority = authority(), capability = try await issue(authority)
        await #expect(throws: AgentTaskScopeError.conflictingParent) {
            try await validate(authority, capability, operation: .createChild, parent: UUID())
        }
        for operation in AgentTaskScopeOperation.allCases where operation != .createChild {
            await #expect(throws: AgentTaskScopeError.targetNotOwned) {
                try await validate(authority, capability, operation: operation, target: UUID())
            }
        }
        #expect(try await validate(authority, capability, operation: .createChild, parent: owner).ownerTaskID == owner)
    }

    @Test func readerScopeAllowsStatusAndDeniesEveryOtherOperation() async throws {
        let authority = authority(), capability = try await issue(authority, operations: [.status])
        #expect(try await validate(authority, capability).allowedOperations == [.status])
        for operation in AgentTaskScopeOperation.allCases where operation != .status {
            await #expect(throws: AgentTaskScopeError.operationDenied) {
                try await validate(authority, capability, operation: operation)
            }
        }
        await #expect(throws: AgentTaskScopeError.operationDenied) {
            try await authority.allowChild(owner: capability.scope, newChildID: UUID())
        }
    }

    @Test func pendingAndExistingChildrenShareEightSlotsAndReservationIsIdempotent() async throws {
        let authority = authority(), existing = Set((0..<7).map { _ in UUID() })
        let capability = try await issue(authority, targets: existing)
        let eighth = UUID()
        _ = try await authority.allowChild(owner: capability.scope, newChildID: eighth)
        _ = try await authority.allowChild(owner: capability.scope, newChildID: eighth)
        #expect(try await validate(authority, capability, operation: .cancel, target: eighth).allowedTargets.contains(eighth))
        await #expect(throws: AgentTaskScopeError.childLimitExceeded) {
            try await authority.allowChild(owner: capability.scope, newChildID: UUID())
        }
        let refreshed = try await issue(authority, targets: existing.union([eighth]))
        await #expect(throws: AgentTaskScopeError.childLimitExceeded) {
            try await authority.allowChild(owner: refreshed.scope, newChildID: UUID())
        }
    }

    @Test func childCannotClaimSiblingOrAnotherRoot() async throws {
        let authority = authority(), first = UUID(), second = UUID()
        let root = try await issue(authority, targets: [first, second])
        let child = try await authority.issue(ownerTaskID: first, providerSessionID: "child", workspaceStableID: workspace,
                                              bindingGeneration: "child-binding", allowedOperations: [.status, .createChild],
                                              allowedTargets: [], lifetime: 30, parentTaskID: owner)
        await #expect(throws: AgentTaskScopeError.targetNotOwned) {
            try await authority.allowChild(owner: child.scope, newChildID: second)
        }
        let otherRoot = UUID()
        _ = try await authority.issue(ownerTaskID: otherRoot, providerSessionID: "other-root", workspaceStableID: workspace,
                                      bindingGeneration: "other-root", allowedOperations: [.status],
                                      allowedTargets: [], lifetime: 30)
        await #expect(throws: AgentTaskScopeError.targetNotOwned) {
            try await authority.allowChild(owner: child.scope, newChildID: otherRoot)
        }
        #expect(try await validate(authority, root, target: second).ownerTaskID == owner)
    }

    @Test func concurrentReservationsCannotOverbookTheOwner() async throws {
        let authority = authority(), root = try await issue(authority)
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        _ = try await authority.allowChild(owner: root.scope, newChildID: UUID())
                        return true
                    } catch AgentTaskScopeError.childLimitExceeded {
                        return false
                    } catch {
                        Issue.record(error)
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(accepted == 8)
    }

    @Test func failedIssuanceDoesNotLeavePartialReservations() async throws {
        let authority = authority()
        await #expect(throws: AgentTaskScopeError.childLimitExceeded) {
            try await issue(authority, targets: Set((0..<9).map { _ in UUID() }))
        }
        let root = try await issue(authority)
        for _ in 0..<8 { _ = try await authority.allowChild(owner: root.scope, newChildID: UUID()) }
        await #expect(throws: AgentTaskScopeError.childLimitExceeded) {
            try await authority.allowChild(owner: root.scope, newChildID: UUID())
        }
    }

    @Test func childIssueCannotEscalateRightsExpiryOrDiscardItsParent() async throws {
        let authority = authority(), childID = UUID()
        _ = try await issue(authority, operations: [.status, .createChild], targets: [childID])
        for operations in [Set([AgentTaskScopeOperation.send]), Set([.cancel])] {
            await #expect(throws: AgentTaskScopeError.missingParentGrant) {
                try await authority.issue(ownerTaskID: childID, providerSessionID: "child", workspaceStableID: workspace,
                                          bindingGeneration: "child", allowedOperations: operations,
                                          allowedTargets: [], lifetime: 30, parentTaskID: owner)
            }
        }
        await #expect(throws: AgentTaskScopeError.missingParentGrant) {
            try await authority.issue(ownerTaskID: childID, providerSessionID: "child", workspaceStableID: workspace,
                                      bindingGeneration: "child", allowedOperations: [.status],
                                      allowedTargets: [], lifetime: 120, parentTaskID: owner)
        }
        await #expect(throws: AgentTaskScopeError.conflictingParent) {
            try await authority.issue(ownerTaskID: childID, providerSessionID: "child", workspaceStableID: workspace,
                                      bindingGeneration: "child", allowedOperations: [.status],
                                      allowedTargets: [], lifetime: 30)
        }
    }

    @Test func depthAndRootBudgetCannotBeReplenishedByChildGrants() async throws {
        let authority = authority()
        var parent = try await issue(authority, budget: AgentTaskScopeBudget(maxDescendants: 4))
        for depth in 1...4 {
            let childID = UUID()
            _ = try await authority.allowChild(owner: parent.scope, newChildID: childID)
            parent = try await authority.issue(ownerTaskID: childID, providerSessionID: "child-\(depth)",
                                               workspaceStableID: workspace, bindingGeneration: "binding-\(depth)",
                                               allowedOperations: parent.scope.allowedOperations, allowedTargets: [],
                                               lifetime: 30, parentTaskID: parent.scope.ownerTaskID)
            #expect(parent.scope.depth == depth)
            #expect(parent.scope.rootTaskID == owner)
        }
        await #expect(throws: AgentTaskScopeError.depthLimitExceeded) {
            try await authority.allowChild(owner: parent.scope, newChildID: UUID())
        }
        let root = try await issue(authority)
        await #expect(throws: AgentTaskScopeError.lineageBudgetExceeded) {
            try await authority.allowChild(owner: root.scope, newChildID: UUID())
        }
    }

    @Test func siblingBranchesConsumeOneRootBudgetAndRevokeAllDoesNotRefillIt() async throws {
        let authority = authority(), childID = UUID()
        let root = try await issue(authority, targets: [childID], budget: AgentTaskScopeBudget(maxDescendants: 2))
        let child = try await authority.issue(ownerTaskID: childID, providerSessionID: "child", workspaceStableID: workspace,
                                              bindingGeneration: "child", allowedOperations: [.createChild],
                                              allowedTargets: [], lifetime: 30, parentTaskID: owner)
        _ = try await authority.allowChild(owner: child.scope, newChildID: UUID())
        await #expect(throws: AgentTaskScopeError.lineageBudgetExceeded) {
            try await authority.allowChild(owner: root.scope, newChildID: UUID())
        }
        await authority.revokeAll()
        let refreshed = try await issue(authority)
        await #expect(throws: AgentTaskScopeError.lineageBudgetExceeded) {
            try await authority.allowChild(owner: refreshed.scope, newChildID: UUID())
        }
    }

    @Test func ancestorRevocationAlsoRevokesDescendantGrants() async throws {
        let authority = authority(), childID = UUID()
        _ = try await issue(authority, targets: [childID])
        let child = try await authority.issue(ownerTaskID: childID, providerSessionID: "child", workspaceStableID: workspace,
                                              bindingGeneration: "child", allowedOperations: [.status],
                                              allowedTargets: [], lifetime: 30, parentTaskID: owner)
        await authority.revokeOwner(owner)
        await #expect(throws: AgentTaskScopeError.revoked) {
            try await authority.validate(token: child.token, callerSessionID: "child", bindingGeneration: "child", operation: .status)
        }
    }

    @Test func recreatedEpochNeverRevivesBearerEvenWithRepeatedFixtureEntropy() async throws {
        let entropy: @Sendable () throws -> [UInt8] = { Array(repeating: 42, count: 32) }
        let first = AgentTaskScopeAuthority(tokenEntropy: entropy)
        let old = try await issue(first)
        let second = AgentTaskScopeAuthority(tokenEntropy: entropy)
        let new = try await issue(second)
        #expect(old.token != new.token)
        await #expect(throws: AgentTaskScopeError.epochMismatch) { try await validate(second, old) }
        #expect(try await validate(second, new).appEpoch != old.scope.appEpoch)
    }

    @Test func staleEnvironmentDictionaryCannotEnrollOrGrantTrustedDispatch() async throws {
        let authority = authority()
        var stale = ["CMUX_TASK_ID": owner.uuidString, "CMUX_WORKSPACE_ID": workspace.uuidString,
                     "CMUX_SESSION_ID": session, "CMUX_BINDING_GENERATION": generation,
                     "CMUX_TASK_TOKEN": "old-environment-token"]
        await #expect(throws: AgentTaskScopeError.malformedToken) {
            try await authority.validate(token: try #require(stale["CMUX_TASK_TOKEN"]),
                                         callerSessionID: stale["CMUX_SESSION_ID"],
                                         bindingGeneration: stale["CMUX_BINDING_GENERATION"], operation: .createChild)
        }
        let staleTask = try #require(stale["CMUX_TASK_ID"])
        let staleID = try #require(UUID(uuidString: staleTask))
        await #expect(throws: AgentTaskScopeError.unknownCapability) {
            try await authority.authorizeTrustedOwner(ownerTaskID: staleID,
                                                      callerSessionID: session, bindingGeneration: generation,
                                                      operation: .createChild)
        }
        // Even a real token inherited from a different conversation is insufficient:
        // the bridge supplies the actual live caller, never the dictionary's session.
        stale["CMUX_TASK_TOKEN"] = try await issue(authority).token
        await #expect(throws: AgentTaskScopeError.sessionMismatch) {
            try await authority.validate(token: try #require(stale["CMUX_TASK_TOKEN"]),
                                         callerSessionID: "unrelated-live-thread",
                                         bindingGeneration: generation, operation: .createChild)
        }
        await #expect(throws: AgentTaskScopeError.sessionMismatch) {
            try await authority.authorizeTrustedOwner(ownerTaskID: owner, callerSessionID: "unrelated-live-thread",
                                                      bindingGeneration: generation, operation: .status)
        }
    }

    @Test func decodedMetadataIsNotEnrollmentAndRevokedMetadataCannotReserveChildren() async throws {
        let issuer = authority(), other = authority(epoch: issuer.epoch)
        let capability = try await issue(issuer)
        let decoded = try JSONDecoder().decode(AgentTaskScope.self, from: JSONEncoder().encode(capability.scope))
        await #expect(throws: AgentTaskScopeError.unknownCapability) {
            try await other.allowChild(owner: decoded, newChildID: UUID())
        }
        await issuer.revokeOwner(owner)
        await #expect(throws: AgentTaskScopeError.revoked) {
            try await issuer.allowChild(owner: decoded, newChildID: UUID())
        }
    }

    @Test func trustedOwnerDispatchRequiresAnIssuedMatchingGrant() async throws {
        let authority = authority()
        _ = try await issue(authority)
        #expect(try await authority.authorizeTrustedOwner(ownerTaskID: owner, callerSessionID: session,
                                                         bindingGeneration: generation, operation: .send).ownerTaskID == owner)
        await #expect(throws: AgentTaskScopeError.sessionMismatch) {
            try await authority.authorizeTrustedOwner(ownerTaskID: owner, callerSessionID: "other",
                                                      bindingGeneration: generation, operation: .send)
        }
        await authority.revokeAll()
        await #expect(throws: AgentTaskScopeError.unknownCapability) {
            try await authority.authorizeTrustedOwner(ownerTaskID: owner, callerSessionID: session,
                                                      bindingGeneration: generation, operation: .send)
        }
    }

    @Test func trustedOwnerDispatchUsesTheGrantThatActuallyAllowsTheOperation() async throws {
        let authority = authority()
        _ = try await issue(authority, operations: [.status])
        let writer = try await issue(authority, operations: [.send])
        #expect(try await authority.authorizeTrustedOwner(ownerTaskID: owner, callerSessionID: session,
                                                         bindingGeneration: generation, operation: .send) == writer.scope)
    }

    @Test func duplicateEntropyCannotReplaceOrReviveAnIssuedToken() async throws {
        let authority = AgentTaskScopeAuthority(tokenEntropy: { Array(repeating: 7, count: 32) })
        let first = try await issue(authority)
        await #expect(throws: AgentTaskScopeError.invalidEntropy) { try await issue(authority) }
        #expect(try await validate(authority, first).ownerTaskID == owner)
        await authority.revokeAll()
        await #expect(throws: AgentTaskScopeError.invalidEntropy) { try await issue(authority) }
        await #expect(throws: AgentTaskScopeError.revoked) { try await validate(authority, first) }
    }

    @Test func invalidLimitsLifetimesAndEntropyFailWithoutGranting() async throws {
        for budget in [AgentTaskScopeBudget(maxDepth: 5), AgentTaskScopeBudget(maxChildrenPerOwner: 9),
                       AgentTaskScopeBudget(maxDescendants: -1)] {
            let authority = authority()
            await #expect(throws: AgentTaskScopeError.invalidBudget) { try await issue(authority, budget: budget) }
        }
        for lifetime in [0.0, -1, .infinity, .nan] {
            let authority = authority()
            await #expect(throws: AgentTaskScopeError.invalidLifetime) { try await issue(authority, lifetime: lifetime) }
        }
        let shortEntropy = AgentTaskScopeAuthority(tokenEntropy: { [1, 2] })
        await #expect(throws: AgentTaskScopeError.invalidEntropy) { try await issue(shortEntropy) }
    }
    @Test func remainingChildCapacityReportsImmutableDirectAndRootBudgetAndRejectsRevokedScope() async throws {
        let authority = authority()
        let grant = try await issue(authority, budget: AgentTaskScopeBudget(maxDepth: 2, maxChildrenPerOwner: 3, maxDescendants: 2))
        #expect(try await authority.remainingChildCapacity(owner: grant.scope) == 2)
        _ = try await authority.allowChild(owner: grant.scope, newChildID: UUID())
        #expect(try await authority.remainingChildCapacity(owner: grant.scope) == 1)
        _ = try await authority.allowChild(owner: grant.scope, newChildID: UUID())
        #expect(try await authority.remainingChildCapacity(owner: grant.scope) == 0)
        await authority.revokeOwner(owner)
        await #expect(throws: AgentTaskScopeError.revoked) { try await authority.remainingChildCapacity(owner: grant.scope) }
        let fresh = try await issue(authority)
        #expect(try await authority.remainingChildCapacity(owner: fresh.scope) == 0)
    }

    @Test func readOnlyAndMaximumDepthScopesCannotPromiseNewWorkerSchedules() async throws {
        let authority = authority()
        let reader = try await issue(authority, operations: [.read])
        await #expect(throws: AgentTaskScopeError.operationDenied) { try await authority.remainingChildCapacity(owner: reader.scope) }
        let shallow = self.authority()
        let full = try await issue(shallow, budget: AgentTaskScopeBudget(maxDepth: 0))
        #expect(try await shallow.remainingChildCapacity(owner: full.scope) == 0)
    }

}
