import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Which file formats NooVeu can open and save on this Mac.
///
/// Tier 1 comes from ImageIO and varies by macOS version, so it is read at run time
/// rather than hard-coded. Tier 2 codecs (phase 3) will register here too.
public enum FormatRegistry {
    /// Uniform type identifiers ImageIO can decode on this system.
    public static let readableTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    /// Uniform type identifiers ImageIO can encode on this system.
    public static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    private static let extensionCache = Mutex<[String: Bool]>([:])

    /// Whether files with this extension can be opened. Cached per extension, so listing a
    /// 10,000-file folder costs one type lookup per distinct extension.
    public static func canRead(fileExtension: String) -> Bool {
        let key = fileExtension.lowercased()
        guard !key.isEmpty else { return false }
        if let known = extensionCache.withLock({ $0[key] }) { return known }
        let result = computeCanRead(key)
        extensionCache.withLock { $0[key] = result }
        return result
    }

    public static func canRead(_ url: URL) -> Bool {
        canRead(fileExtension: url.pathExtension)
    }

    private static func computeCanRead(_ fileExtension: String) -> Bool {
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        if readableTypes.contains(type.identifier) { return true }
        // Vendor aliases, such as a camera's RAW variant, conform to a type ImageIO lists.
        return readableTypes.contains { identifier in
            UTType(identifier).map { type.conforms(to: $0) } ?? false
        }
    }
}
