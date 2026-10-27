import CryptoKit
import Foundation
import Darwin

/// Durable admission for a scoped control command; an uncertain send is never replayed.
public actor AgentTaskCommandLedger {
    /// A stored command response or an unresolved prior dispatch.
    public struct Receipt: Codable, Equatable, Sendable {
        /// Caller-stable operation identity.
        public let id: UUID
        /// SHA256 of canonical arguments, excluding transport credentials.
        public let digest: String
        /// Complete response bytes, absent when acceptance is uncertain.
        public var response: Data?
        /// Time of the most recent durable write.
        public var updatedAt: Date
    }

    /// Why a control command cannot be admitted.
    public enum Failure: Error, Sendable { case conflict, invalidResponse }
    private let directory: URL
    private let now: @Sendable () -> Date

    /// Creates a private command ledger without touching provider state.
    /// - Parameters:
    ///   - directory: App-owned private directory, injected by the composition root.
    ///   - now: Clock used only for receipt timestamps.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Saves dispatch intent before the caller performs a side effect.
    /// - Parameters:
    ///   - id: Stable operation key.
    ///   - arguments: Canonical JSON bytes without credentials.
    /// - Returns: A previous receipt on an identical retry, or nil after preparing a new operation.
    /// - Throws: A conflicting key or a persistence error; the caller must not dispatch.
    public func begin(_ id: UUID, arguments: Data) throws -> Receipt? {
        let digest = SHA256.hash(data: arguments).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
            guard previous.digest == digest else { throw Failure.conflict }
            return previous
        }
        try save(Receipt(id: id, digest: digest, response: nil, updatedAt: now()))
        return nil
    }

    /// Commits an exact response after the operation returns; duplicate reads reuse these bytes.
    /// - Parameters:
    ///   - id: Previously admitted operation.
    ///   - response: Bounded response bytes.
    /// - Throws: Missing admission, oversized response or persistence errors.
    public func complete(_ id: UUID, response: Data) throws {
        guard response.count <= 262_144 else { throw Failure.invalidResponse }
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        var receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        receipt.response = response
        receipt.updatedAt = now()
        try save(receipt)
    }

    /// Atomically replaces the private receipt and synchronizes its contents before acknowledgement.
    private func save(_ receipt: Receipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(receipt.id.uuidString + ".json")
        try JSONEncoder().encode(receipt).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let parent = open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
