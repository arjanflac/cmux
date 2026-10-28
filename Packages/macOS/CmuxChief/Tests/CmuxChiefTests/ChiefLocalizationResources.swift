import Foundation

/// Reads the locale resource emitted into a package bundle, without consulting source files.
struct ChiefLocalizationResources {
    let roots: [URL]

    init(bundle: Bundle) {
        roots = [bundle.resourceURL, bundle.bundleURL].compactMap { $0 }
    }

    init(roots: [URL]) { self.roots = roots }

    func string(for key: String, locale: String) throws -> String {
        // Xcode compiles catalogs; the native SwiftPM backend copies them.
        // A present but corrupt compiled file must not be hidden by the catalog.
        if let url = resourceURL("\(locale).lproj/Localizable.strings") {
            let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
            guard let strings = object as? [String: String], let value = strings[key] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value
        }
        guard let url = resourceURL("Localizable.xcstrings") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let catalog = object as? [String: Any], let strings = catalog["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any], let translations = entry["localizations"] as? [String: Any],
              let translation = translations[locale] as? [String: Any], let unit = translation["stringUnit"] as? [String: Any],
              unit["state"] as? String == "translated", let value = unit["value"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private func resourceURL(_ path: String) -> URL? {
        roots.flatMap { root in
            [root.appendingPathComponent(path), root.appendingPathComponent("Contents/Resources/" + path)]
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
