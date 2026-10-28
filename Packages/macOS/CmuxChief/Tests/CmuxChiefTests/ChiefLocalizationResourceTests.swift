import Foundation
import Testing

@Suite struct ChiefLocalizationResourceTests {
    private let key = "chief.turn.failed"
    private let japanese = "完了できませんでした: %@"

    @Test(arguments: ["", "Contents/Resources/"])
    func compiledStringsKeepTheJapaneseTranslation(prefix: String) throws {
        try withResources { root, resources in
            let url = root.appendingPathComponent(prefix + "ja.lproj/Localizable.strings")
            try write([key: japanese], to: url)
            #expect(try resources.string(for: key, locale: "ja") == japanese)
        }
    }

    @Test(arguments: ["", "Contents/Resources/"])
    func copiedCatalogKeepsTheJapaneseTranslation(prefix: String) throws {
        try withResources { root, resources in
            let catalog = ["sourceLanguage": "en", "strings": [key: ["localizations": [
                "en": ["stringUnit": ["state": "translated", "value": "I couldn’t finish: %@"]],
                "ja": ["stringUnit": ["state": "translated", "value": japanese]]
            ]]]] as [String: Any]
            try write(catalog, to: root.appendingPathComponent(prefix + "Localizable.xcstrings"), json: true)
            #expect(try resources.string(for: key, locale: "ja") == japanese)
        }
    }

    @Test func missingJapaneseNeverUsesEnglishAsEvidence() throws {
        try withResources { root, resources in
            let catalog = ["sourceLanguage": "en", "strings": [key: ["localizations": [
                "en": ["stringUnit": ["state": "translated", "value": "I couldn’t finish: %@"]]
            ]]]] as [String: Any]
            try write(catalog, to: root.appendingPathComponent("Localizable.xcstrings"), json: true)
            #expect(throws: (any Error).self) { try resources.string(for: key, locale: "ja") }
        }
    }

    @Test func corruptCompiledResourceIsNotHiddenByAnotherResource() throws {
        try withResources { root, resources in
            let url = root.appendingPathComponent("ja.lproj/Localizable.strings")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invalid plist".utf8).write(to: url)
            let catalog = ["strings": [key: ["localizations": [
                "ja": ["stringUnit": ["state": "translated", "value": japanese]]
            ]]]] as [String: Any]
            try write(catalog, to: root.appendingPathComponent("Localizable.xcstrings"), json: true)
            #expect(throws: (any Error).self) { try resources.string(for: key, locale: "ja") }
        }
    }

    @Test func missingResourcesFailInsteadOfUsingTheKey() throws {
        try withResources { _, resources in
            #expect(throws: (any Error).self) { try resources.string(for: key, locale: "ja") }
        }
    }

    private func write(_ object: [String: Any], to url: URL, json: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try json ? JSONSerialization.data(withJSONObject: object)
            : PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: url)
    }

    private func withResources(_ body: (URL, ChiefLocalizationResources) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, ChiefLocalizationResources(roots: [root]))
    }
}
