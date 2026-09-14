import XCTest
@testable import AtlasCore

final class RelationshipIndexTests: XCTestCase {
    private func root(_ name: String = "relationship-index") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testScansAllEligibleFilesAndFindsRelationshipsBeyondOldSlice() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        var files: [SourceFile] = []
        for number in 0..<81 {
            let path = "src/File\(number).swift"
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = number == 80 ? String(repeating: "// padding\n", count: 3_000) + "import File0\n" : "let value = \(number)\n"
            try Data(source.utf8).write(to: url)
            files.append(SourceFile(path: path, lines: source.split(separator: "\n", omittingEmptySubsequences: false).count, bytes: source.utf8.count))
        }
        let result = try RelationshipIndex.scan(index: RepositoryIndex(root: directory, files: files))
        XCTAssertEqual(result.eligibleFiles, 81)
        XCTAssertEqual(result.scannedFiles, 81)
        XCTAssertTrue(result.isComplete)
        let view=WorkspaceGraph.build(index:RepositoryIndex(root:directory,files:files),fileIDs:[0,80],sources:[:],relationships:result)
        XCTAssertEqual(view.edges,result.edges)
        XCTAssertTrue(result.edges.contains { $0.from == "file:src/File80.swift" && $0.to == "file:src/File0.swift" })
    }

    func testCancellationThrowsBeforeReading() throws {
        let directory = try root("relationship-cancel"); defer { try? FileManager.default.removeItem(at: directory) }
        let index = RepositoryIndex(root: directory, files: [SourceFile(path: "a.swift", lines: 1, bytes: 1)])
        XCTAssertThrowsError(try RelationshipIndex.scan(index: index, cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUnreadableEligibleFileMakesResultIncomplete() throws {
        let directory = try root("relationship-incomplete"); defer { try? FileManager.default.removeItem(at: directory) }
        let result = try RelationshipIndex.scan(index: RepositoryIndex(root: directory, files: [SourceFile(path: "missing.swift", lines: 1, bytes: 1)]))
        XCTAssertEqual(result.unreadableFiles, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.summary.contains("unreadable"))
    }
}
