import XCTest
@testable import AtlasCore

final class PythonImportTests: XCTestCase {
    private func files(_ paths: [String]) -> [SourceFile] { paths.map { SourceFile(path: $0, lines: 1, bytes: 1) } }

    func testResolvesSrcLayoutAbsoluteAndRelativeImports() {
        let indexed = files(["src/context_graph/__init__.py", "src/context_graph/kernel.py", "src/context_graph/models.py", "src/context_graph/cli.py"])
        let result = ImportResolver(files: indexed).find(source: "from .kernel import ContextKernel\nfrom . import models\nimport context_graph.cli\n", file: indexed[3])
        XCTAssertEqual(result.resolved.map { indexed[$0].path }, ["src/context_graph/kernel.py", "src/context_graph/models.py"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testResolvesParentRelativeAndMultilineImports() {
        let indexed = files(["src/pkg/__init__.py", "src/pkg/sub/__init__.py", "src/pkg/base.py", "src/pkg/sub/child.py"])
        let result = ImportLinks.find(source: "from ..base import (\n  Base\n)\n", file: indexed[3], files: indexed)
        XCTAssertEqual(result.resolved.map { indexed[$0].path }, ["src/pkg/base.py"])
    }

    func testCommentsAndStringsDoNotBecomeImports() {
        let indexed = files(["src/pkg/__init__.py", "src/pkg/main.py"])
        let result = ImportLinks.find(source: "# import pkg.missing\ntext = \"from pkg.missing import Fake\"\nimport pkg.main\n", file: indexed[0], files: indexed)
        XCTAssertEqual(result.resolved.map { indexed[$0].path }, ["src/pkg/main.py"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testFromImportsResolveModuleWithoutReportingImportedSymbol() {
        let indexed = files(["src/package/__init__.py", "src/package/module.py", "src/package/consumer.py"])
        let result = ImportLinks.find(source: "from package import module\nfrom .module import helper\n", file: indexed[2], files: indexed)
        XCTAssertEqual(result.resolved.map { indexed[$0].path }, ["src/package/module.py"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testRelativeImportCannotClimbAbovePackageRoot() {
        let indexed = files(["src/pkg/__init__.py", "src/pkg/child.py"])
        let result = ImportLinks.find(source: "from ...outside import value\n", file: indexed[1], files: indexed)
        XCTAssertTrue(result.resolved.isEmpty)
    }
}
