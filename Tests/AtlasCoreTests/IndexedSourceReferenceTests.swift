import XCTest
@testable import AtlasCore

final class IndexedSourceReferenceTests:XCTestCase {
    private let index=RepositoryIndex(root:URL(fileURLWithPath:"/repo/project"),files:[
        SourceFile(path:"notes/Plan for week.md",lines:0,bytes:80),
        SourceFile(path:"src/main.swift",lines:12,bytes:100),
        SourceFile(path:"graph/private.md",lines:0,bytes:100)
    ])
    func testOpensOnlyExistingIndexedReferences() {
        XCTAssertEqual(IndexedSourceReference.fileID("src/main.swift",in:index),1)
        XCTAssertEqual(IndexedSourceReference.fileID("/repo/project/src/main.swift",in:index),1)
        XCTAssertEqual(IndexedSourceReference.fileID("file:///repo/project/notes/Plan%20for%20week.md",in:index),0)
        XCTAssertEqual(IndexedSourceReference.fileID("file://localhost/repo/project/src/main.swift",in:index),1)
        XCTAssertNil(IndexedSourceReference.fileID("src/unknown.swift",in:index))
    }
    func testRejectsRemoteSchemesHostsAndDifferentRoots() {
        for ref in ["https://example.com/src/main.swift","file://other-host/repo/project/src/main.swift","file://user@localhost/repo/project/src/main.swift","file://localhost:80/repo/project/src/main.swift","file:///repo/project/src/main.swift?query=1","file:///repo/project/src/main.swift#claim","/repo/other/src/main.swift","/repo/project-other/src/main.swift","synthetic:note"] {
            XCTAssertNil(IndexedSourceReference.fileID(ref,in:index),ref)
        }
    }
    func testRejectsTraversalPrivateDataAndControlCharacters() {
        for ref in ["../project/src/main.swift","/repo/project/../project/src/main.swift","file:///repo/project/%2e%2e/project/src/main.swift","graph/private.md","file:///repo/project/graph/private.md","src/main.swift\n",""] {
            XCTAssertNil(IndexedSourceReference.fileID(ref,in:index),ref)
        }
    }
}
