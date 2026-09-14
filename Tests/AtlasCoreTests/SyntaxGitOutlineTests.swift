import XCTest
@testable import AtlasCore

private func kind(_ spans:[SyntaxSpans.Span], at location: Int) -> SyntaxSpans.Kind? {
    spans.first { NSLocationInRange(location, $0.range) }?.kind
}

final class SyntaxSpanTests: XCTestCase {
    func testCommentMarkerInsideStringStaysAString() {
        let text = #"let site = "https://example.com/path" // real comment"#
        let spans = SyntaxSpans.scan(text, language: "swift")
        let slashes = (text as NSString).range(of: "//").location          // inside the URL
        let comment = (text as NSString).range(of: "// real").location
        XCTAssertEqual(kind(spans, at: slashes), .string)
        XCTAssertEqual(kind(spans, at: comment), .comment)
    }

    func testQuoteInsideCommentDoesNotOpenAString() {
        let text = "// it's fine\nlet value = 1\n"
        let spans = SyntaxSpans.scan(text, language: "swift")
        XCTAssertEqual(kind(spans, at: (text as NSString).range(of: "it's").location), .comment)
        XCTAssertEqual(kind(spans, at: (text as NSString).range(of: "let").location), .keyword)
        XCTAssertEqual(kind(spans, at: (text as NSString).range(of: "1").location), .number)
    }

    func testHashIsACommentOnlyWhereTheLanguageSaysSo() {
        let python = "#note\nx = 1\n", swift = "#available(macOS 14, *)\n"
        XCTAssertEqual(kind(SyntaxSpans.scan(python, language: "py"), at: 0), .comment)
        XCTAssertNil(kind(SyntaxSpans.scan(swift, language: "swift"), at: 0))
    }

    func testUnterminatedQuoteStopsAtTheLineAndEscapesAreConsumed() {
        let text = "let a = \"open\nlet b = \"esc\\\" still\"\n"
        let spans = SyntaxSpans.scan(text, language: "swift")
        let second = (text as NSString).range(of: "let b").location
        XCTAssertEqual(kind(spans, at: second), .keyword, "an unterminated string must not swallow the rest of the file")
    }
}

final class OutlineIndexTests: XCTestCase {
    func testFindsDeclarationsBeyondFunctionsAndClasses() {
        let content = """
        extension MetalMap {
        impl Renderer for Metal {
        type Result = String
        export const handler = async (request) => {
        let plain = 4
        """
        let lines = OutlineIndex.entries(content).map(\.line)
        XCTAssertEqual(lines, [0, 1, 2, 3], "the bare assignment on the last line is not a declaration")
    }

    func testRespectsTheEntryLimit() {
        let content = (0..<50).map { "func item\($0)() {}" }.joined(separator: "\n")
        XCTAssertEqual(OutlineIndex.entries(content, limit: 10).count, 10)
    }
}

final class GitScopeTests: XCTestCase {
    func testStatusInASubfolderKeepsOnlyItsOwnPathsAndStripsThePrefix() {
        var payload = Data()
        for record in ["A  app/sources/added.swift", "R  app/sources/new.swift", "app/sources/old.swift", " M other/elsewhere.swift"] {
            payload.append(contentsOf: Array(record.utf8)); payload.append(0)
        }
        let changes = GitChanges.parse(payload, strippingPrefix: "app/")
        XCTAssertEqual(Set(changes.statuses.keys), ["sources/added.swift", "sources/new.swift"])
        XCTAssertNil(changes.statuses["other/elsewhere.swift"], "paths outside the opened folder belong to the wider repository")
    }

    func testRelativePrefixIsEmptyAtTheRepositoryRoot() {
        let repository = URL(fileURLWithPath: "/tmp/atlas-repo")
        XCTAssertEqual(LocalGit.relativePrefix(of: repository, in: repository), "")
        XCTAssertEqual(LocalGit.relativePrefix(of: repository.appendingPathComponent("app/sources"), in: repository), "app/sources/")
    }

    func testRepositoryRootIsFoundFromASubfolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-subfolder-\(UUID())")
        let nested = root.appendingPathComponent("app/sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(LocalGit.repositoryRoot(for: nested)?.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNil(LocalGit.repositoryRoot(for: nested, limit: 1))
    }
}

final class LineCountTests: XCTestCase {
    func testCountsTrailingLineWithAndWithoutFinalNewline() {
        XCTAssertEqual(RepoIndexer.countLines(Data("a\nb\nc".utf8)), 3)
        XCTAssertEqual(RepoIndexer.countLines(Data("a\nb\nc\n".utf8)), 3)
        XCTAssertEqual(RepoIndexer.countLines(Data("single".utf8)), 1)
    }
}
