public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads and downsamples user-selected images away from the main actor.
public actor WorkspaceIconImporter {
    /// An image could not be read or converted within the import limits.
    public enum ImportError: Error, Sendable {
        /// The selected file exceeds the bounded input size.
        case tooLarge
        /// The selected file does not contain a supported image.
        case invalidImage
    }

    private let maximumInputByteCount: Int

    /// Creates an importer with a bounded file-read budget.
    /// - Parameter maximumInputByteCount: Maximum source image size, in bytes.
    public init(maximumInputByteCount: Int = 10_485_760) {
        self.maximumInputByteCount = min(10_485_760, max(1, maximumInputByteCount))
    }

    /// Imports the first image frame, preserving aspect ratio and transparency.
    /// - Parameter url: The file explicitly chosen by the user.
    /// - Returns: A self-contained PNG thumbnail with a content fingerprint.
    /// - Throws: An import error or a file-read error; the workspace remains unchanged.
    public func importIcon(from url: URL) throws -> WorkspaceIcon {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumInputByteCount + 1) ?? Data()
        guard data.count <= maximumInputByteCount else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: WorkspaceIcon.maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ImportError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), let icon = WorkspaceIcon(pngData: output as Data) else {
            throw ImportError.invalidImage
        }
        return icon
    }
}
