import Foundation

/// Writes private frontend transport files; these files never submit provider work.
public actor AgentTaskPanelRepository {
    /// Read-only locations delivered to one verified frontend.
    public struct Paths: Sendable {
        /// Aggregate status snapshot with no bearer token.
        public let snapshot: URL
        /// Private transport-only capability, consumed by the bridge helper.
        public let scope: URL
    }
    private let directory: URL
    /// Creates a store rooted in the app's private runtime directory.
    /// - Parameter directory: Explicit app-owned path.
    public init(directory: URL) { self.directory = directory }

    /// Creates or renews one verified frontend's files.
    /// - Parameters:
    ///   - id: App-owned registration identity, never a caller-supplied filesystem path.
    ///   - scope: Bounded private credential JSON, never model context.
    ///   - snapshot: Bounded passive status JSON.
    /// - Returns: Stable locations for this registration.
    /// - Throws: Persistence errors; no partially issued capability should be acknowledged.
    public func put(_ id: UUID, scope: Data, snapshot: Data) throws -> Paths {
        guard scope.count <= 16_384, snapshot.count <= 16_384 else { throw CocoaError(.fileWriteUnknown) }
        let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let paths = Paths(snapshot: folder.appendingPathComponent("status.json"), scope: folder.appendingPathComponent("scope.json"))
        try replace(scope, at: paths.scope)
        try replace(snapshot, at: paths.snapshot)
        return paths
    }

    /// Refreshes status without changing an already granted transport credential.
    /// - Parameters:
    ///   - id: Existing registration.
    ///   - snapshot: Passive aggregate status.
    /// - Throws: Persistence or size errors.
    public func update(_ id: UUID, snapshot: Data) throws {
        guard snapshot.count <= 16_384 else { throw CocoaError(.fileWriteUnknown) }
        try replace(snapshot, at: directory.appendingPathComponent(id.uuidString).appendingPathComponent("status.json"))
    }

    /// Revokes only this registration's disposable transport files.
    /// - Parameter id: Registration to remove; provider sessions are unaffected.
    public func remove(_ id: UUID) throws {
        let path = directory.appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// The temporary inode is private before its contents are written or renamed.
    private func replace(_ data: Data, at destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
    }
}
