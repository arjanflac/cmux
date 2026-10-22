public import Foundation
import CryptoKit
import ImageIO

/// A bounded PNG thumbnail that travels with a workspace's saved identity.
public struct WorkspaceIcon: Codable, Equatable, Sendable {
    /// Maximum encoded size accepted from a saved workspace.
    public static let maximumByteCount = 32_768
    /// Maximum pixel dimension of a saved thumbnail.
    public static let maximumPixelDimension = 64
    /// Encoded thumbnail, independent of the original image's path.
    public let pngData: Data
    /// Content identity used by sidebar snapshots and image views.
    public let fingerprint: String

    /// Creates an icon from an already normalized PNG thumbnail.
    /// - Parameter pngData: PNG bytes with dimensions no larger than 64 pixels.
    public init?(pngData: Data) {
        guard pngData.count >= 24, pngData.count <= Self.maximumByteCount else { return nil }
        let bytes = Array(pngData.prefix(24))
        guard bytes.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
              bytes[12..<16].elementsEqual([73, 72, 68, 82]) else { return nil }
        let width = bytes[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = bytes[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0,
              width <= UInt32(Self.maximumPixelDimension), height <= UInt32(Self.maximumPixelDimension),
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
        self.pngData = pngData
        self.fingerprint = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes and validates a saved thumbnail, deriving its content identity again.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        guard let icon = Self(pngData: data) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid workspace icon thumbnail")
        }
        self = icon
    }

    /// Encodes only the thumbnail; its fingerprint is derived on load.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pngData)
    }

    /// Compares content identities without scanning thumbnail bytes during sidebar updates.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }
}
