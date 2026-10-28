import CryptoKit
import Foundation

/// Validated provenance of the quiet frontend shipped inside the current app bundle.
///
/// The release is the sole version source. A valid manifest does not establish
/// daemon compatibility; callers must still require the frontend's read-only check.
public struct CodexQuietManifest: Sendable {
    /// Exact stock CLI and daemon version required by this bundled frontend.
    public let version: String
    private let binarySHA256: String

    /// Validates the artifact manifest without reading or launching any executable.
    /// - Parameter data: The current bundle's artifact manifest, never a global override.
    /// - Returns: Nil for malformed provenance or an unsupported artifact kind.
    public init?(data: Data) {
        guard data.count <= 65_536, let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.attachOnly, payload.release == "rust-v0.164.0", payload.repository == "https://github.com/openai/codex",
              payload.platform == "Darwin", ["arm64", "aarch64"].contains(payload.architecture),
              Self.isHex(payload.commit, length: 40), Self.isHex(payload.binarySHA256, length: 64),
              payload.release.hasPrefix("rust-v"), payload.release.utf8.count <= 64 else { return nil }
        let version = String(payload.release.dropFirst(6))
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ component in
            !component.isEmpty && (component.count == 1 || component.first != "0")
                && component.allSatisfy { "0123456789".contains($0) }
        }) else { return nil }
        self.version = version; binarySHA256 = payload.binarySHA256
    }

    /// Preserves the restore probe's existing exact artifact checksum fence.
    /// - Parameter binary: Already loaded frontend bytes from the trusted bundle.
    /// - Returns: Whether these bytes match the manifest's recorded checksum.
    public func verifiesBinary(_ binary: Data) -> Bool {
        SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined() == binarySHA256
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private struct Payload: Decodable {
        let release: String
        let commit: String
        let repository: String
        let binarySHA256: String
        let attachOnly: Bool
        let platform: String
        let architecture: String

        private enum CodingKeys: String, CodingKey {
            case release, commit, repository, platform, architecture
            case binarySHA256 = "binary_sha256", attachOnly = "attach_only"
        }
    }
}
