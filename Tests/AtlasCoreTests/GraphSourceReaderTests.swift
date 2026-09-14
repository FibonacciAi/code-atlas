import XCTest
@testable import AtlasCore

final class GraphSourceReaderTests: XCTestCase {
    private func temporaryRoot(_ name: String = "graph-reader") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testReadsIndexedMarkdownAndRelativeDocumentLinkData() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let guide = "# Guide\nSee [the notes](notes.txt).\n"
        try Data(guide.utf8).write(to: docs.appendingPathComponent("guide.md"))
        try Data("relative document notes".utf8).write(to: docs.appendingPathComponent("notes.txt"))

        let index = try RepoIndexer.scan(root, includeMedia: true)
        let guideID = try XCTUnwrap(index.files.firstIndex { $0.path == "docs/guide.md" })
        let notesID = try XCTUnwrap(index.files.firstIndex { $0.path == "docs/notes.txt" })
        XCTAssertEqual(try GraphSourceReader.read(index: index, fileID: guideID), guide)
        XCTAssertEqual(try GraphSourceReader.read(index: index, fileID: notesID), "relative document notes")
    }

    func testReadIsBoundedToTwentyFourKiBAndHonorsSmallerLimit() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = String(repeating: "0123456789abcdef\n", count: 2_000)
        try Data(content.utf8).write(to: root.appendingPathComponent("large.md"))
        let index = try RepoIndexer.scan(root, includeMedia: true)
        let id = try XCTUnwrap(index.files.firstIndex { $0.path == "large.md" })
        XCTAssertEqual(try GraphSourceReader.read(index: index, fileID: id, limit: 7).utf8.count, 7)
        XCTAssertLessThanOrEqual(try GraphSourceReader.read(index: index, fileID: id, limit: 100_000).utf8.count, 24 * 1024)
    }

    func testRejectsMissingIDAndBinaryDocx() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("attachment.docx"))
        let index = try RepoIndexer.scan(root, includeMedia: true)
        XCTAssertThrowsError(try GraphSourceReader.read(index: index, fileID: 999))
        let id = try XCTUnwrap(index.files.firstIndex { $0.path == "attachment.docx" })
        XCTAssertThrowsError(try GraphSourceReader.read(index: index, fileID: id))
    }

    func testRejectsFileReplacedBySymlinkAfterIndexing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.swift")
        let outside = root.deletingLastPathComponent().appendingPathComponent("graph-reader-outside-\(UUID()).swift")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("let safe = true".utf8).write(to: source)
        try Data("let privateValue = true".utf8).write(to: outside)
        let index = try RepoIndexer.scan(root, includeMedia: true)
        let id = try XCTUnwrap(index.files.firstIndex { $0.path == "source.swift" })
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try GraphSourceReader.read(index: index, fileID: id))
    }

    func testValidatedURLRejectsUnapprovedPrivateRoot() {
        let root = URL(fileURLWithPath: "/Users/example/credentials")
        let index = RepositoryIndex(root: root, files: [SourceFile(path: "graph.swift", lines: 1, bytes: 1)])
        XCTAssertThrowsError(try GraphSourceReader.read(index: index, fileID: 0))
    }
}
