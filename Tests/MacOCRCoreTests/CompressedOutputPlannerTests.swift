import Foundation
import Testing
@testable import MacOCRCore

@Suite("CompressedOutputPlanner")
struct CompressedOutputPlannerTests {
    @Test("Unique names keep the original stem")
    func uniqueNamesKeepStem() {
        let planner = CompressedOutputPlanner(displayPaths: [
            "/data/a/photo.png",
            "/data/b/invoice.png"
        ])
        #expect(planner.stems["/data/a/photo.png"] == "photo")
        #expect(planner.stems["/data/b/invoice.png"] == "invoice")
    }

    @Test("Same basename in different folders is disambiguated by relative path")
    func sameBasenameIsDisambiguated() {
        let planner = CompressedOutputPlanner(displayPaths: [
            "/data/d1/photo.png",
            "/data/d2/photo.png"
        ])
        #expect(planner.stems["/data/d1/photo.png"] == "d1__photo")
        #expect(planner.stems["/data/d2/photo.png"] == "d2__photo")
    }

    @Test("Planned URLs never collide")
    func plannedURLsNeverCollide() {
        let paths = ["/data/d1/photo.png", "/data/d2/photo.png", "/data/photo.png"]
        let planner = CompressedOutputPlanner(displayPaths: paths)
        let dir = URL(fileURLWithPath: "/out")
        let urls = paths.compactMap { planner.url(for: $0, in: dir, format: .jpeg) }
        #expect(urls.count == 3)
        #expect(Set(urls.map(\.path)).count == 3)
    }

    @Test("PDF page suffix is preserved")
    func pdfPageSuffixPreserved() {
        let planner = CompressedOutputPlanner(displayPaths: [
            "/data/doc.pdf#page=1",
            "/data/doc.pdf#page=2"
        ])
        #expect(planner.stems["/data/doc.pdf#page=1"] == "doc-p1")
        #expect(planner.stems["/data/doc.pdf#page=2"] == "doc-p2")
    }

    @Test("Same folder, same stem, different extensions gets an index suffix")
    func sameFolderSameStemDifferentExtensions() {
        let planner = CompressedOutputPlanner(displayPaths: [
            "/data/photo.png",
            "/data/photo.jpg"
        ])
        #expect(Set(planner.stems.values).count == 2)
    }

    @Test("URL uses the target format extension")
    func urlUsesFormatExtension() {
        let planner = CompressedOutputPlanner(displayPaths: ["/data/photo.png"])
        let dir = URL(fileURLWithPath: "/out")
        #expect(planner.url(for: "/data/photo.png", in: dir, format: .webp)?.lastPathComponent == "photo.webp")
        #expect(planner.url(for: "/data/photo.png", in: dir, format: .jpeg)?.lastPathComponent == "photo.jpg")
    }

    @Test("Unknown displayPath has no planned URL")
    func unknownDisplayPathHasNoURL() {
        let planner = CompressedOutputPlanner(displayPaths: ["/data/photo.png"])
        #expect(planner.url(for: "/data/other.png", in: URL(fileURLWithPath: "/out"), format: .jpeg) == nil)
    }
}
