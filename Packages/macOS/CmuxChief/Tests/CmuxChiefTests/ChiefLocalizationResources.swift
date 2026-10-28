import Foundation

/// Reads the locale resource emitted into a package bundle, without consulting source files.
struct ChiefLocalizationResources {
    let roots: [URL]

    init(bundle: Bundle) {
        roots = [bundle.resourceURL, bundle.bundleURL].compactMap { $0 }
    }

    init(roots: [URL]) { self.roots = roots }

    func string(for key: String, locale: String) throws -> String {
        let candidates = roots.flatMap { root in
            [root.appendingPathComponent("\(locale).lproj/Localizable.strings"),
             root.appendingPathComponent("Contents/Resources/\(locale).lproj/Localizable.strings")]
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let strings = NSDictionary(contentsOf: url) as? [String: String], let value = strings[key] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
