import Foundation
import Testing
@testable import NooVeuCore

@Suite("FolderNavigator")
struct FolderNavigatorTests {
    @Test func listsImagesInFinderOrderAndSkipsEverythingElse() throws {
        let folder = try TemporaryFolder()
        for name in ["img10.jpg", "img2.jpg", "B.png", "a.HEIC", "notes.txt", ".hidden.jpg", "raw.CR3"] {
            try folder.touch(name)
        }
        try FileManager.default.createDirectory(at: folder.file("sub.jpg"), withIntermediateDirectories: false)

        let listing = try FolderNavigator.listing(of: folder.url)

        #expect(listing.items.map(\.lastPathComponent) == ["a.HEIC", "B.png", "img2.jpg", "img10.jpg", "raw.CR3"])
    }

    @Test func findsTheOpenedFileThroughASymlinkedFolder() throws {
        let folder = try TemporaryFolder()
        try folder.touch("a.jpg")
        try folder.touch("b.jpg")
        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("NooVeuAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.url)
        defer { try? FileManager.default.removeItem(at: alias) }

        let listing = try FolderNavigator.listing(containing: folder.file("b.jpg"))

        #expect(listing.index(of: folder.file("b.jpg")) == 1)
        #expect(listing.index(of: alias.appendingPathComponent("b.jpg")) == 1)
    }

    @Test func anOpenedImageIsListedEvenWithoutAKnownExtension() throws {
        let folder = try TemporaryFolder()
        for name in ["a.png", "z.png"] {
            TestImages.write(width: 8, height: 8, to: folder.file(name))
        }
        TestImages.write(width: 8, height: 8, to: folder.file("noext"))
        TestImages.write(width: 8, height: 8, to: folder.file("wrongext.dat"))
        TestImages.write(width: 8, height: 8, to: folder.file(".hidden.png"))

        for name in ["noext", "wrongext.dat", ".hidden.png"] {
            let listing = try FolderNavigator.listing(containing: folder.file(name))

            let index = try #require(listing.index(of: folder.file(name)), "\(name)")
            #expect(listing.items[index].lastPathComponent == name)
            #expect(listing.items.map(\.lastPathComponent).contains("a.png"))
            // The result stays in Finder order.
            let names = listing.items.map(\.lastPathComponent)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test func aTextFileIsNotAddedJustBecauseItWasOpened() throws {
        let folder = try TemporaryFolder()
        try folder.touch("a.png")
        try folder.touch("readme", contents: "hello")

        let listing = try FolderNavigator.listing(containing: folder.file("readme"))

        #expect(listing.index(of: folder.file("readme")) == nil)
    }

    @Test func steppingWrapsOnlyWhenAsked() {
        let listing = FolderListing(folder: URL(fileURLWithPath: "/x"), items: (0..<5).map { URL(fileURLWithPath: "/x/\($0).jpg") })

        #expect(listing.index(4, offsetBy: 1, wrapping: true) == 0)
        #expect(listing.index(0, offsetBy: -1, wrapping: true) == 4)
        #expect(listing.index(4, offsetBy: 1, wrapping: false) == nil)
        #expect(listing.index(2, offsetBy: 2, wrapping: false) == 4)
    }

    @Test func preloadOrderInterleavesOutward() {
        let listing = FolderListing(folder: URL(fileURLWithPath: "/x"), items: (0..<10).map { URL(fileURLWithPath: "/x/\($0).jpg") })

        #expect(listing.preloadOrder(around: 5, ahead: 3, behind: 1, wrapping: false) == [6, 4, 7, 8])
        #expect(listing.preloadOrder(around: 9, ahead: 2, behind: 1, wrapping: true) == [0, 8, 1])
        #expect(listing.preloadOrder(around: 0, ahead: 0, behind: 0, wrapping: true) == [])
    }

    @Test func preloadOrderPutsThePreviousImageFirstWhenTravellingBackward() {
        let listing = FolderListing(folder: URL(fileURLWithPath: "/x"), items: (0..<10).map { URL(fileURLWithPath: "/x/\($0).jpg") })

        #expect(listing.preloadOrder(around: 5, ahead: 1, behind: 3, wrapping: false, favouringForward: false) == [4, 6, 3, 2])
        #expect(listing.preloadOrder(around: 5, ahead: 1, behind: 3, wrapping: false, favouringForward: true) == [6, 4, 3, 2])
    }

    @Test func preloadOrderNeverRepeatsInSmallFolders() {
        let listing = FolderListing(folder: URL(fileURLWithPath: "/x"), items: (0..<3).map { URL(fileURLWithPath: "/x/\($0).jpg") })

        #expect(listing.preloadOrder(around: 0, ahead: 3, behind: 3, wrapping: true) == [1, 2])
    }
}

@Suite("FormatRegistry")
struct FormatRegistryTests {
    @Test(arguments: ["jpg", "JPEG", "png", "heic", "avif", "webp", "jxl", "tif", "cr3", "nef", "dng", "exr", "psd"])
    func readsCommonFormats(fileExtension: String) {
        #expect(FormatRegistry.canRead(fileExtension: fileExtension))
    }

    @Test(arguments: ["txt", "pdf", "mov", "", "zip"])
    func ignoresNonImages(fileExtension: String) {
        #expect(!FormatRegistry.canRead(fileExtension: fileExtension))
    }

    @Test func writesTheCoreFormats() {
        for type in ["public.jpeg", "public.png", "public.heic", "public.tiff"] {
            #expect(FormatRegistry.writableTypes.contains(type), "\(type)")
        }
    }
}
