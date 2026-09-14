import XCTest
@testable import AtlasCore

final class GraphCoverageTests: XCTestCase {
    private func makeIndex(fileCount: Int = 120) throws -> (URL, RepositoryIndex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-coverage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try (0..<fileCount).map { number -> SourceFile in
            let path = "group\(number % 3)/File\(number).swift"
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("let value = \(number)\n".utf8).write(to: url)
            return SourceFile(path: path, lines: 1, bytes: 16)
        }
        return (root, RepositoryIndex(root: root, files: files))
    }

    func testRelationshipScanCoversMoreThanDisplayLimit() throws {
        let (root, index) = try makeIndex(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try RelationshipIndex.scan(index: index)
        XCTAssertEqual(result.eligibleFiles, 120)
        XCTAssertEqual(result.scannedFiles, 120)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.excludedFiles, 0)
    }

    func testFolderOverviewAndDrilldownPagingCoverEveryNode() throws {
        let (root, index) = try makeIndex(); defer { try? FileManager.default.removeItem(at: root) }
        let relationships = try RelationshipIndex.scan(index: index)
        let allIDs = Array(index.files.indices)
        let overview = WorkspaceGraph.build(index: index, fileIDs: allIDs, sources: [:], maxNodes: 100, relationships: relationships)
        XCTAssertEqual(overview.nodes.count, 3)
        XCTAssertTrue(overview.nodes.allSatisfy { $0.id.hasPrefix("folder:") })
        XCTAssertTrue(overview.summary.contains("Folder overview"))

        let firstPage = WorkspaceGraph.build(index: index, fileIDs: allIDs, sources: [:], maxNodes: 17, relationships: relationships, folder: "group0", page: 0)
        XCTAssertEqual(firstPage.pageCount, 3)
        XCTAssertEqual(firstPage.nodes.count, 17)
        var seen = Set(firstPage.nodes.map(\.id))
        for page in 1..<firstPage.pageCount {
            let next = WorkspaceGraph.build(index: index, fileIDs: allIDs, sources: [:], maxNodes: 17, relationships: relationships, folder: "group0", page: page)
            seen.formUnion(next.nodes.map(\.id))
        }
        XCTAssertEqual(seen.count, 40)
        XCTAssertTrue(seen.allSatisfy { $0.hasPrefix("file:group0/") })
    }
}
