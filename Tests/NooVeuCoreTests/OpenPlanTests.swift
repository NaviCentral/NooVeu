import Foundation
import Testing
@testable import NooVeuCore

@Suite("OpenPlan")
struct OpenPlanTests {
    private func urls(_ paths: [String]) -> [URL] { paths.map { URL(fileURLWithPath: $0) } }
    private let neverAFolder: (URL) -> Bool = { _ in false }

    @Test func manyFilesInOneFolderOpenOneWindow() {
        let files = urls((1...300).map { "/photos/trip/\($0).jpg" })

        #expect(OpenPlan.windows(for: files, isFolder: neverAFolder) == [files[0]])
    }

    @Test func eachFolderGetsItsOwnWindowInOrder() {
        let files = urls(["/a/1.jpg", "/b/1.jpg", "/a/2.jpg", "/c/1.jpg", "/b/2.jpg"])

        #expect(OpenPlan.windows(for: files, isFolder: neverAFolder).map(\.path) == ["/a/1.jpg", "/b/1.jpg", "/c/1.jpg"])
    }

    @Test func aFolderAndAFileInsideItShareAWindow() {
        let input = urls(["/photos", "/photos/1.jpg", "/other/2.jpg"])

        let plan = OpenPlan.windows(for: input) { $0.path == "/photos" }

        #expect(plan.map(\.path) == ["/photos", "/other/2.jpg"])
    }

    @Test func neverMoreWindowsThanTheLimit() {
        let files = urls((1...50).map { "/folder\($0)/1.jpg" })

        #expect(OpenPlan.windows(for: files, limit: 8, isFolder: neverAFolder).count == 8)
        #expect(OpenPlan.windows(for: files, isFolder: neverAFolder).count == 8, "the default limit is 8")
    }

    @Test func aLimitOfZeroOrLessOpensNothing() {
        let files = urls(["/a/1.jpg", "/b/1.jpg"])

        #expect(OpenPlan.windows(for: files, limit: 0, isFolder: neverAFolder).isEmpty)
        #expect(OpenPlan.windows(for: files, limit: -3, isFolder: neverAFolder).isEmpty)
    }

    @Test func nothingOpensNothing() {
        #expect(OpenPlan.windows(for: [], isFolder: neverAFolder).isEmpty)
    }
}
