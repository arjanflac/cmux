import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal scroll speed settings file", .serialized)
struct TerminalScrollSpeedSettingsFileStoreTests {
    @Test
    func settingsFileStoreAppliesTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(1.5) { defaults in
            #expect(defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double == 1.5)
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == 1.5)
        }
    }

    @Test
    func settingsFileStoreClampsOutOfRangeTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(99) { defaults in
            #expect(
                defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double ==
                    TerminalScrollSpeedSettings.maximumMultiplier
            )
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == TerminalScrollSpeedSettings.maximumMultiplier)
        }
    }

    @Test
    func settingsFileStoreClampsBelowMinimumTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(0.1) { defaults in
            #expect(
                defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double ==
                    TerminalScrollSpeedSettings.minimumMultiplier
            )
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == TerminalScrollSpeedSettings.minimumMultiplier)
        }
    }

    @Test
    func settingsFileImportsCmuxOnlyLaunchPreferences() throws {
        let suiteName = "cmux-launch-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let workspace = UUID().uuidString
        try """
        {"terminal":{"codexQuietFrontend":true,"workspaceLaunchDirectories":{"\(workspace)":"/products/lightwell"}}}
        """.write(to: file, atomically: true, encoding: .utf8)
        _ = KeyboardShortcutSettingsFileStore(primaryPath: file.path, fallbackPath: nil,
            additionalFallbackPaths: [], notificationCenter: NotificationCenter(),
            userDefaults: defaults, startWatching: false, isUserDefaultsKeyForcedByProfile: { _ in false })
        #expect(defaults.object(forKey: "terminal.codexQuietFrontend") as? Bool == true)
        #expect(defaults.dictionary(forKey: "terminal.workspaceLaunchDirectories") as? [String: String] == [workspace: "/products/lightwell"])
    }

    private func loadScrollSpeedSetting(_ value: Double, verify: (UserDefaults) throws -> Void) throws {
        // Keep the import separate from the running app's managed defaults and
        // observers, which can restore their own settings during these writes.
        let suiteName = "cmux-terminal-scroll-speed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "terminal": {
            "scrollSpeed": \(value)
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )

        #expect(store.activeSourcePath == settingsFileURL.path)
        try verify(defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-terminal-scroll-speed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
