import Foundation

/// The openable images in one folder, in Finder order.
public struct FolderListing: Sendable, Equatable {
    public let folder: URL
    public let items: [URL]

    public init(folder: URL, items: [URL]) {
        self.folder = folder
        self.items = items
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public func index(of url: URL) -> Int? {
        let target = FolderNavigator.canonical(url)
        if let exact = items.firstIndex(of: target) { return exact }
        // On a case-insensitive volume the same file can be spelled with different case
        // (`photo.png` for `Photo.PNG`): match by name, then confirm it is the same file.
        guard let identity = FileIdentity(target) else { return nil }
        return items.firstIndex {
            $0.lastPathComponent.caseInsensitiveCompare(target.lastPathComponent) == .orderedSame
                && FileIdentity($0) == identity
        }
    }

    /// The index `delta` steps from `index`, wrapping past either end when `wrapping` is set.
    public func index(_ index: Int, offsetBy delta: Int, wrapping: Bool) -> Int? {
        guard !items.isEmpty else { return nil }
        if wrapping {
            // Reduce first: `index + delta` would overflow for a huge delta.
            return (((index + delta % count) % count) + count) % count
        }
        let (target, overflow) = index.addingReportingOverflow(delta)
        return !overflow && items.indices.contains(target) ? target : nil
    }

    /// Indices near `index` in the order they should be preloaded: interleaved outward, nearest
    /// first. `ahead` counts images after `index` in the listing and `behind` images before it.
    /// At equal distance the image in the direction of travel comes first: with
    /// `favouringForward` the next image, otherwise the previous one.
    /// With `ahead: 2, behind: 1` going forward the order is next, previous, next-but-one.
    public func preloadOrder(around index: Int, ahead: Int, behind: Int, wrapping: Bool,
                             favouringForward: Bool = true) -> [Int] {
        var order: [Int] = []
        var seen: Set<Int> = [index]
        // More than the other images in the folder is pointless (and would spin for a huge `ahead`).
        let reach = min(max(ahead, behind), items.count)
        guard reach > 0 else { return [] }
        for step in 1...reach {
            let next = step <= ahead ? self.index(index, offsetBy: step, wrapping: wrapping) : nil
            let previous = step <= behind ? self.index(index, offsetBy: -step, wrapping: wrapping) : nil
            for candidate in favouringForward ? [next, previous] : [previous, next] {
                if let candidate, seen.insert(candidate).inserted { order.append(candidate) }
            }
        }
        return order
    }
}

public enum FolderNavigator {
    /// Lists the folder that contains `file`.
    ///
    /// The file itself is always in the result when ImageIO can open it, even if its name has
    /// no extension, an unusual one, or starts with a dot: opening a file must never leave you
    /// unable to flip away from it.
    public static func listing(containing file: URL) throws -> FolderListing {
        let listing = try listing(of: file.deletingLastPathComponent())
        let target = canonical(file)
        guard listing.index(of: target) == nil, ImageDecoder.probe(target) != nil else { return listing }
        let items = (listing.items + [target]).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return FolderListing(folder: listing.folder, items: items)
    }

    /// Lists the openable images directly inside `folder`, skipping hidden files and
    /// subfolders, sorted the way Finder sorts names ("img2" before "img10").
    public static func listing(of folder: URL) throws -> FolderListing {
        let base = canonical(folder: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)

        // Filter on the extension first: it needs no file-system call.
        let candidates = names.filter { name in
            !name.hasPrefix(".") && FormatRegistry.canRead(fileExtension: (name as NSString).pathExtension)
        }
        let files = candidates.filter { name in
            var isDirectory: ObjCBool = false
            let path = base.appendingPathComponent(name, isDirectory: false).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let sorted = files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return FolderListing(
            folder: base,
            items: sorted.map { base.appendingPathComponent($0, isDirectory: false) }
        )
    }

    /// A stable form of a file URL, so the same file always compares equal
    /// (`/tmp/a.jpg` and `/private/tmp/a.jpg` are one file). Use it for any URL that becomes a
    /// cache key.
    public static func canonical(_ file: URL) -> URL {
        canonical(folder: file.deletingLastPathComponent())
            .appendingPathComponent(file.lastPathComponent, isDirectory: false)
    }

    static func canonical(folder: URL) -> URL {
        URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Which file a path leads to, independent of how it is spelled: the volume and the file's number.
struct FileIdentity: Hashable {
    let device: Int32
    let inode: UInt64

    init?(_ url: URL) {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) == 0 } ?? false
        }
        guard found else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}
