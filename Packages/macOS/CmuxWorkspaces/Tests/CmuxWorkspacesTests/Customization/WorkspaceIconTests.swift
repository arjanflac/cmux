import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxWorkspaces

@Suite("Workspace icon import and persistence")
struct WorkspaceIconTests {
    @Test("large images become bounded thumbnails without losing aspect ratio")
    func downsampling() async throws {
        let fixture = try makeImage(width: 512, height: 256)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let icon = try await WorkspaceIconImporter().importIcon(from: fixture.url)
        let source = try #require(CGImageSourceCreateWithData(icon.pngData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 32)
        #expect(icon.pngData.count <= WorkspaceIcon.maximumByteCount)
        #expect(image.alphaInfo != .none)
    }

    @Test("oversized sources are rejected before decoding")
    func inputLimit() async throws {
        let fixture = try makeImage(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await #expect(throws: WorkspaceIconImporter.ImportError.tooLarge) {
            try await WorkspaceIconImporter(maximumInputByteCount: 1).importIcon(from: fixture.url)
        }
    }

    @Test("non-images are rejected")
    func invalidImage() async throws {
        let fixture = try makeImage(width: 1, height: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("not an image".utf8).write(to: fixture.url)
        await #expect(throws: WorkspaceIconImporter.ImportError.invalidImage) {
            try await WorkspaceIconImporter().importIcon(from: fixture.url)
        }
    }

    @Test("serialized thumbnails round-trip after the original file is removed")
    func selfContainedRoundTrip() async throws {
        let fixture = try makeImage(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let icon = try await WorkspaceIconImporter().importIcon(from: fixture.url)
        let encoded = try JSONEncoder().encode(icon)
        try FileManager.default.removeItem(at: fixture.url)
        let decoded = try JSONDecoder().decode(WorkspaceIcon.self, from: encoded)
        #expect(decoded == icon)
        #expect(decoded.pngData == icon.pngData)
        #expect(decoded.fingerprint == icon.fingerprint)
    }

    @Test("saved oversized or malformed thumbnails are rejected")
    func invalidStoredIcon() throws {
        #expect(WorkspaceIcon(pngData: Data(repeating: 0, count: WorkspaceIcon.maximumByteCount + 1)) == nil)
        #expect(WorkspaceIcon(pngData: Data("invalid".utf8)) == nil)
        var truncatedHeader = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82])
        truncatedHeader.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 1])
        #expect(WorkspaceIcon(pngData: truncatedHeader) == nil)
        let encoded = try JSONEncoder().encode(Data("invalid".utf8))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceIcon.self, from: encoded) }
    }

    @MainActor
    @Test("icon mutations survive restart independently of title and color")
    func recoveryJournal() async throws {
        let fixture = try makeImage(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let icon = try await WorkspaceIconImporter().importIcon(from: fixture.url)
        let suite = "WorkspaceIconTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let store = WorkspaceCustomizationStore(defaults: defaults)
        store.setCustomIcon(icon, for: id)
        store.setCustomTitle("Project", for: id)
        store.setCustomColor("#123456", for: id)
        let reloaded = WorkspaceCustomizationStore(defaults: defaults)
        #expect(reloaded.customization(for: id)?.customIcon == .value(icon))
        store.setCustomIcon(nil, for: id)
        #expect(reloaded.customization(for: id)?.customIcon == .cleared)
        #expect(reloaded.customization(for: id)?.customTitle == .value("Project"))
        #expect(reloaded.customization(for: id)?.customColor == .value("#123456"))
    }

    @Test("old customization records do not clear icons from session snapshots")
    func legacyJournal() throws {
        let old = Data(#"{"customTitle":{"absent":{}},"customColor":{"absent":{}}}"#.utf8)
        #expect(try JSONDecoder().decode(WorkspaceCustomization.self, from: old).customIcon == .absent)
    }

    private func makeImage(width: Int, height: Int) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.png")
        let pixels = Data(repeating: 128, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (directory, url)
    }
}
