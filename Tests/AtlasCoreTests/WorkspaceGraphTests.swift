import XCTest
@testable import AtlasCore

final class WorkspaceGraphTests: XCTestCase {
    func testMarkdownExportWrapsTheDiagram() {
        let index=RepositoryIndex(root:URL(fileURLWithPath:"/example"),files:[SourceFile(path:"main.swift",lines:1,bytes:10)])
        let graph=WorkspaceGraph.build(index:index,fileIDs:[0],sources:[:])
        let markdown=graph.markdownDocument()
        XCTAssertTrue(markdown.hasPrefix("# Code Atlas graph\n"))
        XCTAssertTrue(markdown.contains("```mermaid\n"+graph.mermaid))
        XCTAssertTrue(markdown.hasSuffix("\n```\n"))
    }

    private func fixture() -> (RepositoryIndex, [Int: String]) {
        let files = [SourceFile(path: "docs/guide.md", lines: 3, bytes: 20), SourceFile(path: "src/main.swift", lines: 3, bytes: 20), SourceFile(path: "src/Helper.swift", lines: 2, bytes: 20), SourceFile(path: "isolated.swift", lines: 1, bytes: 10)]
        let index = RepositoryIndex(root: URL(fileURLWithPath: "/repo"), files: files)
        return (index, [0: "[helper](../src/Helper.swift)", 1: "import Foundation\nimport Helper"])
    }

    func testMarkdownRelativeLinksAndIsolatedFiles() {
        let (index, sources) = fixture()
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0, 1, 2, 3], sources: sources)
        XCTAssertTrue(graph.edges.contains(WorkspaceGraph.Edge(from: "file:docs/guide.md", to: "file:src/Helper.swift", label: "links")))
        XCTAssertTrue(graph.nodes.contains { $0.id == "file:isolated.swift" })
    }

    func testSelectionNeighborhoodAndStableLimits() {
        let (index, sources) = fixture()
        let one = WorkspaceGraph.build(index: index, fileIDs: [0, 1, 2, 3], sources: sources, selectedFileID: 1, maxNodes: 2)
        let two = WorkspaceGraph.build(index: index, fileIDs: [3, 2, 1, 0], sources: sources, selectedFileID: 1, maxNodes: 2)
        XCTAssertTrue(one.nodes.contains { $0.fileID == 1 })
        XCTAssertLessThanOrEqual(one.nodes.count, 2)
        XCTAssertLessThanOrEqual(one.edges.count, one.totalEdgeCount)
        XCTAssertEqual(one.nodes, two.nodes)
        XCTAssertEqual(one.mermaid, two.mermaid)
        XCTAssertTrue(one.summary.contains("omitted"))
    }

    func testSelectedFileIsIncludedWhenCallerFileListOmitsIt() {
        let (index, sources) = fixture()
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0], sources: sources, selectedFileID: 1, maxNodes: 1)
        XCTAssertEqual(graph.nodes.first?.fileID, 1)
    }

    func testSelectedNeighborhoodOmitsUnrelatedFiles() {
        let (index, sources) = fixture()
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0, 1, 2, 3], sources: sources, selectedFileID: 1, maxNodes: 10, selectedNeighborhoodOnly: true)
        XCTAssertTrue(graph.nodes.contains { $0.fileID == 1 })
        XCTAssertTrue(graph.nodes.contains { $0.fileID == 2 })
        XCTAssertFalse(graph.nodes.contains { $0.fileID == 0 || $0.fileID == 3 })
        XCTAssertTrue(graph.edges.allSatisfy { edge in
            edge.from == "file:src/main.swift" || edge.to == "file:src/main.swift"
        })
    }

    func testMissingEndpointsAndEvidenceRequireExactIndexedReference() throws {
        let (index, sources) = fixture()
        let projection = try PersonalProjection.parse([
            "contract": "context-pack.v1", "deployment_id": "personal",
            "entities": [["entity_id": "goal", "entity_type": "goal", "display_name": "Ship"]],
            "evidence": [["evidence_id": "exact", "source_uri": "src/main.swift"], ["evidence_id": "bad", "source_uri": "src/unknown.swift"]],
            "claims": [["entity_id": "goal", "predicate": "status", "value": "active", "evidence_ids": ["exact", "bad"]]],
            "relationships": [["source_entity_id": "goal", "target_entity_id": "missing", "relationship_type": "related"]]
        ])
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0, 1, 2, 3], sources: sources, projection: projection)
        XCTAssertTrue(graph.edges.contains { $0.from == "context:goal" && $0.to == "file:src/main.swift" && $0.label == "evidence" })
        XCTAssertFalse(graph.edges.contains { $0.to.contains("unknown") || $0.to.contains("missing") })
    }

    func testMermaidEscapesInjectionAndExposesAliases() {
        let index = RepositoryIndex(root: URL(fileURLWithPath: "/repo"), files: [SourceFile(path: "weird.swift", lines: 1, bytes: 1)])
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0], sources: [0: "let x = 1"])
        XCTAssertEqual(graph.aliasToNodeID["n0"], "file:weird.swift")
        XCTAssertFalse(graph.mermaid.contains("]\n    n"))
        XCTAssertTrue(graph.mermaid.hasPrefix("graph LR"))
    }

    func testMermaidGroupsFoldersAndDeemphasizesLexicalImports() {
        let (index, sources) = fixture()
        let graph = WorkspaceGraph.build(index: index, fileIDs: [0, 1, 2, 3], sources: sources)
        XCTAssertTrue(graph.mermaid.contains("subgraph group"))
        XCTAssertTrue(graph.mermaid.contains("src"))
        XCTAssertTrue(graph.mermaid.contains("direction LR"))
        XCTAssertTrue(graph.mermaid.contains("-.->"))
        XCTAssertFalse(graph.mermaid.contains("import candidate"))
        XCTAssertTrue(graph.summary.contains("lexical import candidates"))
    }

    func testDuplicateProjectionIDsDoNotCrash() throws {
        let index = RepositoryIndex(root: URL(fileURLWithPath: "/repo"), files: [SourceFile(path: "a.swift", lines: 1, bytes: 1)])
        let projection = try PersonalProjection.parse([
            "contract": "context-pack.v1", "deployment_id": "personal",
            "entities": [["entity_id": "same", "entity_type": "goal", "display_name": "First"], ["entity_id": "same", "entity_type": "goal", "display_name": "Second"]]
        ])
        let graph = WorkspaceGraph.build(index: index, fileIDs: [], sources: [:], projection: projection)
        XCTAssertEqual(graph.nodes.filter { $0.contextID == "same" }.count, 1)
    }
}
