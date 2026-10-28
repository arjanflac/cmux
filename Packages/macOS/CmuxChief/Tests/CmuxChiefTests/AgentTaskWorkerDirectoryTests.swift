import Foundation
import Testing
@testable import CmuxChief

@MainActor @Suite("Bounded authorized worker directory")
struct AgentTaskWorkerDirectoryTests {
    private let workspace = UUID()
    private let ownerID = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(id: UUID = UUID(), parent: UUID? = nil, workspace: UUID? = nil,
                        phase: AgentTaskRecord.Phase = .completed,
                        lifecycle: AgentTaskRequest.Lifecycle = .persistent) -> AgentTaskRecord {
        let input = AgentTaskRequest(provider: .claude, prompt: "PRIVATE PROMPT BODY\nNEVER EXPOSE THIS", workspaceID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/private-path-marker"), model: "fixture-model",
            presentation: .background, parentTaskID: parent, workspaceStableID: workspace ?? self.workspace,
            lifecycle: lifecycle)
        var value = AgentTaskRecord(id: id, request: input, now: date)
        value.title = "Architecture reviewer"; value.phase = phase
        value.sessionID = "PRIVATE_PROVIDER_SESSION"; value.result = "PRIVATE RESULT BODY"
        value.detail = "PRIVATE ATTENTION DETAIL"
        return value
    }

    private func coordinator(_ repository: any AgentTaskRepository,
                             backend: TurnFixtureBackend = TurnFixtureBackend()) async throws -> AgentTaskCoordinator {
        let value = AgentTaskCoordinator(backend: backend, repository: repository, present: { _, _ in
            Issue.record("Directory reads must not open terminals"); return UUID()
        }, reconnect: { _, _ in UUID() })
        try await value.restore()
        return value
    }

    private func access(_ ids: Set<UUID>, owner: UUID? = nil, workspace: UUID? = nil) -> AgentTaskWorkerDirectoryAccess {
        AgentTaskWorkerDirectoryAccess(ownerTaskID: owner ?? ownerID, workspaceStableID: workspace ?? self.workspace,
                                      allowedTaskIDs: ids)
    }

    @Test func explicitTargetsAreNotAnAncestryOrWorkspaceWildcard() async throws {
        let repository = TurnFixtureTaskRepository(), backend = TurnFixtureBackend()
        let child = UUID(), grandchild = UUID(), peer = UUID(), foreign = UUID(), otherWorkspace = UUID()
        await repository.save(record(id: ownerID))
        await repository.save(record(id: child, parent: ownerID))
        await repository.save(record(id: grandchild, parent: child))
        await repository.save(record(id: peer))
        await repository.save(record(id: foreign, parent: peer))
        await repository.save(record(id: otherWorkspace, parent: ownerID, workspace: UUID()))
        let owner = try await coordinator(repository, backend: backend)
        let direct = try await owner.workers(AgentTaskWorkerDirectoryQuery()) {
            access([ownerID, child, peer, foreign, otherWorkspace])
        }
        #expect(direct.workers.map(\.taskID) == [child])
        let descendant = try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access([grandchild]) }
        #expect(descendant.workers.map(\.taskID) == [grandchild])
        #expect(await backend.submittedCount == 0)
        #expect(await backend.cancelled.isEmpty)
    }

    @Test func listingCannotBroadenARealCapability() async throws {
        let repository = TurnFixtureTaskRepository(), child = UUID(), grandchild = UUID()
        await repository.save(record(id: ownerID))
        await repository.save(record(id: child, parent: ownerID))
        await repository.save(record(id: grandchild, parent: child))
        let owner = try await coordinator(repository), authority = AgentTaskScopeAuthority()
        let grant = try await authority.issue(ownerTaskID: ownerID, providerSessionID: "verified",
            workspaceStableID: workspace, bindingGeneration: "current", allowedOperations: [.read],
            allowedTargets: [child], lifetime: 300)
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery()) {
            let current = try await authority.validate(token: grant.token, callerSessionID: "verified",
                                                       bindingGeneration: "current", operation: .read)
            return access(current.allowedTargets)
        }
        #expect(page.workers.map(\.taskID) == [child])
        await #expect(throws: AgentTaskScopeError.targetNotOwned) {
            try await authority.validate(token: grant.token, callerSessionID: "verified", bindingGeneration: "current",
                                         operation: .read, targetTaskID: grandchild)
        }
    }

    @Test func defaultRetirementFilterAndDiagnosticFlagNeverExpandReadTargets() async throws {
        let repository = TurnFixtureTaskRepository()
        let active = record(parent: ownerID), pendingID = UUID(), retiredID = UUID(), forbiddenID = UUID()
        await repository.save(record(id: ownerID)); await repository.save(active)
        for id in [pendingID, retiredID, forbiddenID] {
            var retired = record(id: id, parent: ownerID)
            var receipt = AgentTaskRetirement(operationID: id, acknowledgedAt: date)
            if id != pendingID { receipt.retiredAt = date }
            retired.retirement = receipt
            await repository.save(retired)
        }
        let owner = try await coordinator(repository)
        let allowed: Set<UUID> = [active.id, pendingID, retiredID]
        let normal = try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access(allowed) }
        #expect(normal.workers.map(\.taskID) == [active.id])
        let diagnostic = try await owner.workers(AgentTaskWorkerDirectoryQuery(includeRetired: true)) { access(allowed) }
        #expect(Set(diagnostic.workers.map(\.taskID)) == allowed)
        #expect(diagnostic.workers.first { $0.taskID == pendingID }?.retirement == .pending)
        #expect(diagnostic.workers.first { $0.taskID == retiredID }?.followUp == .retired)
        #expect(!diagnostic.workers.contains { $0.taskID == forbiddenID })
    }

    @Test func UUIDPaginationIsStableAcrossActivityChangesAndHasExplicitFinalNullCursor() async throws {
        let repository = TurnFixtureTaskRepository()
        let ids = (1...7).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        await repository.save(record(id: ownerID))
        for id in ids { await repository.save(record(id: id, parent: ownerID)) }
        let owner = try await coordinator(repository)
        var cursor: UUID?, seen: [UUID] = []
        repeat {
            let page = try await owner.workers(AgentTaskWorkerDirectoryQuery(cursor: cursor, limit: 2)) { access(Set(ids)) }
            #expect(page.workers.count <= 2)
            seen += page.workers.map(\.taskID)
            if !page.hasMore {
                let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
                #expect(value["next_cursor"] is NSNull)
                #expect(page.nextCursor == nil)
                break
            }
            cursor = page.nextCursor
        } while true
        #expect(seen == ids)
        let beyond = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        #expect(try await owner.workers(AgentTaskWorkerDirectoryQuery(cursor: beyond)) { access(Set(ids)) }.workers.isEmpty)
    }

    @Test(arguments: [#"{"cursor":""}"#, #"{"cursor":"not-a-uuid"}"#, #"{"cursor":1}"#,
        #"{"limit":0}"#, #"{"limit":51}"#, #"{"limit":true}"#, #"{"limit":1.5}"#,
        #"{"limit":"2"}"#, #"{"limit":null}"#, #"{"include_retired":"true"}"#, #"{"include_retired":null}"#])
    func invalidParametersDoNotSilentlyRestartOrWidenDirectory(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AgentTaskWorkerDirectoryQuery.self, from: Data(json.utf8))
        }
    }

    @Test func payloadContainsSmallSanitizedMetadataOnly() async throws {
        let repository = TurnFixtureTaskRepository(), childID = UUID()
        await repository.save(record(id: ownerID))
        var child = record(id: childID, parent: ownerID)
        child.title = "\u{1B}\u{00}Reviewer\n" + String(repeating: "a", count: 1_000)
        child.model = "\u{1B}model\n" + String(repeating: "b", count: 1_000)
        await repository.save(child)
        let owner = try await coordinator(repository)
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access([childID]) }
        let encoded = try JSONEncoder().encode(page), string = String(decoding: encoded, as: UTF8.self)
        for secret in ["PRIVATE PROMPT", "PRIVATE RESULT", "PRIVATE_PROVIDER_SESSION", "private-path-marker", "PRIVATE ATTENTION"] {
            #expect(!string.contains(secret))
        }
        let worker = try #require(page.workers.first)
        #expect(worker.title.unicodeScalars.count <= 100 && worker.model!.unicodeScalars.count <= 80)
        #expect(!worker.title.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try #require(object["workers"] as? [[String: Any]])
        #expect(Set(rows[0].keys).isSubset(of: ["task_id", "provider", "title", "model", "lifecycle", "retirement",
            "phase", "latest_operation_id", "reusable", "follow_up", "updated_at"]))
    }

    @Test func followUpMetadataIsConservativeAndNeverPromisesProviderAvailability() async throws {
        let repository = TurnFixtureTaskRepository()
        await repository.save(record(id: ownerID))
        var expected: [UUID: AgentTaskWorkerSummary.FollowUp] = [:]
        for (phase, reason) in [(AgentTaskRecord.Phase.completed, AgentTaskWorkerSummary.FollowUp.requiresPreflight),
            (.needsInput, .needsInput), (.running, .working), (.disconnected, .unreconciled)] {
            let child = record(parent: ownerID, phase: phase)
            await repository.save(child); expected[child.id] = reason
        }
        var missing = record(parent: ownerID); missing.sessionID = nil
        await repository.save(missing); expected[missing.id] = .missingSession
        let oneShot = record(parent: ownerID, lifecycle: .oneShot)
        await repository.save(oneShot); expected[oneShot.id] = .oneShot
        let owner = try await coordinator(repository)
        // Restored active work is uncertain until the provider is reconciled.
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access(Set(expected.keys)) }
        for child in page.workers {
            let reason = child.phase == .disconnected ? .unreconciled : expected[child.taskID]
            #expect(child.followUp == reason)
            #expect(child.reusable == (child.followUp == .requiresPreflight))
        }
    }

    @Test(.timeLimit(.minutes(1))) func authorityIsRevalidatedAfterDurableReads() async throws {
        let repository = WorkerDirectoryFixtureRepository(), gate = TurnFixtureGate(), childID = UUID()
        await repository.save(record(id: ownerID)); await repository.save(record(id: childID, parent: ownerID))
        for index in 1...105 {
            var unrelated = record(); unrelated.updatedAt = date.addingTimeInterval(Double(index))
            await repository.save(unrelated)
        }
        let owner = try await coordinator(repository), authority = AgentTaskScopeAuthority()
        let grant = try await authority.issue(ownerTaskID: ownerID, providerSessionID: "verified", workspaceStableID: workspace,
            bindingGeneration: "current", allowedOperations: [.read], allowedTargets: [childID], lifetime: 300)
        await repository.holdRead(childID, gate: gate)
        let read = Task { try await owner.workers(AgentTaskWorkerDirectoryQuery()) {
            let current = try await authority.validate(token: grant.token, callerSessionID: "verified", bindingGeneration: "current", operation: .read)
            return access(current.allowedTargets)
        } }
        await gate.waitUntilEntered()
        await authority.revokeOwner(ownerID)
        await gate.open()
        await #expect(throws: AgentTaskScopeError.revoked) { try await read.value }
    }

    @Test func finalAuthorityCanNarrowButCannotExpandTheInitialRead() async throws {
        let repository = TurnFixtureTaskRepository(), first = UUID(), second = UUID(), extra = UUID()
        await repository.save(record(id: ownerID))
        for id in [first, second, extra] { await repository.save(record(id: id, parent: ownerID)) }
        let owner = try await coordinator(repository)
        var calls = 0
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery()) {
            calls += 1
            return access(calls == 1 ? [first, second] : [second, extra])
        }
        #expect(calls == 2)
        #expect(page.workers.map(\.taskID) == [second])
    }

    @Test func changedOwnerOrWorkspaceFailsInsteadOfSwitchingTheDirectory() async throws {
        let repository = TurnFixtureTaskRepository()
        await repository.save(record(id: ownerID))
        let owner = try await coordinator(repository)
        var calls = 0
        await #expect(throws: AgentTaskWorkerDirectoryQuery.Failure.authorizationChanged) {
            try await owner.workers(AgentTaskWorkerDirectoryQuery()) {
                calls += 1
                return access([], owner: calls == 1 ? ownerID : UUID())
            }
        }
    }
    @Test func realDurableRepositoryRediscoveryDoesNotRepopulateOrExpandRecentCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-worker-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentTaskFileRepository(directory: directory)
        let child = record(parent: ownerID)
        try await repository.save(record(id: ownerID)); try await repository.save(child)
        for index in 1...105 {
            var other = record(); other.updatedAt = date.addingTimeInterval(Double(index))
            try await repository.save(other)
        }
        let owner = try await coordinator(repository)
        #expect(owner.records[child.id] == nil)
        let count = owner.records.count
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access([child.id]) }
        #expect(page.workers.map(\.taskID) == [child.id])
        #expect(owner.records[child.id] == nil && owner.records.count == count)
        let raw = try JSONDecoder().decode(AgentTaskRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent(child.id.uuidString + ".json")))
        #expect(raw.result == "PRIVATE RESULT BODY")
        let actual = try await repository.read(child.id)?.result
        #expect(actual == "PRIVATE RESULT BODY")
    }

    @Test(.timeLimit(.minutes(1))) func canonicalWorkspaceChangeOverridesAnEarlierDurableSnapshot() async throws {
        let repository = WorkerDirectoryFixtureRepository(), gate = TurnFixtureGate()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        await repository.save(record(id: ownerID))
        var movable = record(id: first, parent: ownerID); movable.workingDirectory = URL(fileURLWithPath: "/tmp")
        await repository.save(movable); await repository.save(record(id: second, parent: ownerID))
        for index in 1...105 {
            var unrelated = record(); unrelated.updatedAt = date.addingTimeInterval(Double(index))
            await repository.save(unrelated)
        }
        let owner = try await coordinator(repository)
        await repository.holdRead(second, gate: gate)
        let read = Task { try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access([first, second]) } }
        await gate.waitUntilEntered()
        // Uses the real coordinator attachment mutation, with a fixture presenter.
        // The directory must not return the earlier workspace's stale metadata.
        _ = try await owner.attach(first, workspaceID: UUID(), workspaceStableID: UUID())
        await gate.open()
        #expect(try await read.value.workers.map(\.taskID) == [second])
    }

    @Test func changedDurableAncestryIsNotTurnedIntoAnOwnershipGrant() async throws {
        let repository = WorkerDirectoryFixtureRepository(), child = UUID()
        await repository.save(record(id: ownerID)); await repository.save(record(id: child, parent: ownerID))
        for index in 1...105 {
            var unrelated = record(); unrelated.updatedAt = date.addingTimeInterval(Double(index))
            await repository.save(unrelated)
        }
        let owner = try await coordinator(repository)
        #expect(owner.records[child] == nil)
        // The known lineage index is only a discovery candidate set. Saved
        // ancestry/workspace still has to match before metadata can be exposed.
        await repository.save(record(id: child, parent: UUID()))
        #expect(try await owner.workers(AgentTaskWorkerDirectoryQuery()) { access([child]) }.workers.isEmpty)
    }

    @Test func modelOwnerFieldsCannotSelectAnotherDirectory() async throws {
        let repository = TurnFixtureTaskRepository(), child = UUID(), foreignOwner = UUID(), foreignChild = UUID()
        await repository.save(record(id: ownerID)); await repository.save(record(id: child, parent: ownerID))
        await repository.save(record(id: foreignOwner)); await repository.save(record(id: foreignChild, parent: foreignOwner))
        let owner = try await coordinator(repository)
        let body = Data("{\"owner_task_id\":\"\(foreignOwner.uuidString)\",\"task_id\":\"\(foreignOwner.uuidString)\"}".utf8)
        let query = try JSONDecoder().decode(AgentTaskWorkerDirectoryQuery.self, from: body)
        let page = try await owner.workers(query) { access([child, foreignOwner, foreignChild]) }
        #expect(page.workers.map(\.taskID) == [child])
    }

    @Test func maximumPageFitsSocketBudgetAndDoesNotLeakProviderState() async throws {
        let repository = TurnFixtureTaskRepository()
        await repository.save(record(id: ownerID))
        var ids: Set<UUID> = []
        for _ in 0..<51 {
            var worker = record(parent: ownerID)
            worker.title = String(repeating: "😀", count: 100)
            worker.model = String(repeating: "😀", count: 80)
            await repository.save(worker); ids.insert(worker.id)
        }
        let owner = try await coordinator(repository)
        let page = try await owner.workers(AgentTaskWorkerDirectoryQuery(limit: 50)) { access(ids) }
        #expect(page.workers.count == 50 && page.hasMore)
        #expect(try JSONEncoder().encode(page).count < 60_000)
    }

    @Test func actualNativeCatalogAdvertisesDirectoryAndPersistentWorkerOptions() throws {
        let artifact = try JSONSerialization.jsonObject(with: AgentTaskToolCatalog().tools().line)
        let namespaces = try #require(artifact as? [[String: Any]])
        let tools = try #require(namespaces.first?["tools"] as? [[String: Any]])
        let schema = try #require(tools.first?["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let actions = try #require(properties["action"] as? [String: Any])
        #expect((actions["enum"] as? [String])?.contains("workers") == true)
        let body = try #require(properties["body"] as? [String: Any])
        let fields = try #require(body["properties"] as? [String: Any])
        let lifecycle = try #require(fields["lifecycle"] as? [String: Any])
        #expect(lifecycle["enum"] as? [String] == ["persistent", "oneShot"])
        let limit = try #require(fields["limit"] as? [String: Any])
        #expect(limit["maximum"] as? Int == 50)
        #expect(limit["default"] as? Int == (try AgentTaskWorkerDirectoryQuery()).limit)
        #expect(fields["owner_task_id"] == nil)
    }

}
