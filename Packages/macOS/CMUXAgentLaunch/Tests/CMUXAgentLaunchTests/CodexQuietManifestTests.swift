import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexQuietManifestTests {
    private let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test(arguments: ["0.164.0", "0.165.0", "1.0.12"])
    func exactVersionComesFromTheBundledRelease(version: String) throws {
        let manifest = try #require(CodexQuietManifest(data: data(["release": "rust-v" + version])))
        #expect(manifest.version == version)
        #expect(manifest.verifiesBinary(Data("abc".utf8)))
        #expect(!manifest.verifiesBinary(Data("abcd".utf8)))
    }

    @Test(arguments: ["0.165.0", "rust-v0.165", "rust-v0.165.0\n", "rust-v00.165.0", "rust-v0.165.0-beta", "rust-v0.１６５.0"])
    func malformedReleaseCannotNormalizeIntoEligibility(release: String) throws {
        #expect(CodexQuietManifest(data: try data(["release": release])) == nil)
    }

    @Test func provenanceAndArtifactKindRemainRequired() throws {
        for mutation: [String: Any] in [
            ["attach_only": false], ["attach_only": 1], ["repository": "https://example.com/codex"],
            ["platform": "Linux"], ["architecture": "x86_64"], ["commit": "360319d8"],
            ["binary_sha256": "bad"], ["release": 165]
        ] {
            #expect(CodexQuietManifest(data: try data(mutation)) == nil)
        }
        #expect(CodexQuietManifest(data: Data("invalid JSON".utf8)) == nil)
        #expect(CodexQuietManifest(data: Data(repeating: 32, count: 65_537)) == nil)
    }

    private func data(_ overrides: [String: Any]) throws -> Data {
        var value: [String: Any] = ["release": "rust-v0.165.0", "commit": String(repeating: "a", count: 40),
            "repository": "https://github.com/openai/codex", "platform": "Darwin", "architecture": "arm64",
            "attach_only": true, "binary_sha256": checksum]
        value.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
