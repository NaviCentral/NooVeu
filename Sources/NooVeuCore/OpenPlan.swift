import Foundation

/// Decides which windows to open when the system hands the app several files or folders at once
/// (Finder's "Open With" on a selection, or several command-line arguments).
///
/// One window per folder is enough: a window flips through its whole folder, so selecting 300
/// photos in one folder should open one window, not 300.
public enum OpenPlan {
    /// The files or folders to open in a window each, in order, at most `limit` of them.
    /// - Parameter isFolder: Whether a URL is a folder (it is its own group); a file belongs to the
    ///   group of its parent folder.
    public static func windows(
        for urls: [URL],
        limit: Int = 8,
        isFolder: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    ) -> [URL] {
        guard limit > 0 else { return [] }
        var seen: Set<URL> = []
        var result: [URL] = []
        for url in urls {
            let group = isFolder(url) ? url : url.deletingLastPathComponent()
            guard seen.insert(FolderNavigator.canonical(folder: group)).inserted else { continue }
            result.append(url)
            if result.count >= limit { break }
        }
        return result
    }
}
