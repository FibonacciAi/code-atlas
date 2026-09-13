import XCTest
@testable import AtlasCore

final class AtlasCoreTests: XCTestCase {
    func testMixedContentUsesMetadataWhileDefaultRemainsSourceOnly() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-media-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data("let value=1\n".utf8).write(to:root.appendingPathComponent("main.swift"))
        try Data("<html></html>".utf8).write(to:root.appendingPathComponent("page.html"))
        for name in ["photo.heic","clip.mov","sound.wav","paper.pdf","notes.docx","binary.swift","unknown.bin"] {
            try Data([0,255,0,254]).write(to:root.appendingPathComponent(name))
        }
        let clip=try FileHandle(forWritingTo:root.appendingPathComponent("clip.mov"))
        try clip.truncate(atOffset:UInt64(RepoIndexer.maxFileBytes*2)); try clip.close()
        let original=try RepoIndexer.scan(root)
        XCTAssertEqual(original.files.map(\.path),["main.swift","page.html"])
        let mixed=try RepoIndexer.scan(root,includeMedia:true)
        XCTAssertEqual(mixed.files.count,7)
        XCTAssertEqual(mixed.files.first(where:{$0.path=="clip.mov"})?.bytes,RepoIndexer.maxFileBytes*2)
        XCTAssertEqual(mixed.files.first(where:{$0.path=="clip.mov"})?.lines,0)
        XCTAssertEqual(mixed.files.first(where:{$0.path=="photo.heic"})?.kind,.image)
        XCTAssertEqual(mixed.files.first(where:{$0.path=="page.html"})?.kind,.html)
        XCTAssertEqual(mixed.files.first(where:{$0.path=="notes.docx"})?.kind,.document)
        XCTAssertThrowsError(try RepoIndexer.readSource(root:root,path:"photo.heic"))
    }
    func testMediaValidationRejectsPrivatePathsTraversalAndSymlinks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-media-safety-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data([0,1]).write(to:root.appendingPathComponent("photo.png"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.png"),withDestinationURL:root.appendingPathComponent("photo.png"))
        XCTAssertNoThrow(try RepoIndexer.validatedURL(root:root,path:"photo.png"))
        XCTAssertThrowsError(try RepoIndexer.validatedURL(root:root,path:"link.png"))
        for path in ["../photo.png","/photo.png","graph/photo.png","credentials.pdf","Dork/photo.png","App.app/photo.png",""] {
            XCTAssertFalse(SourcePolicy.allowedContent(path),path)
            XCTAssertThrowsError(try RepoIndexer.validatedURL(root:root,path:path))
        }
        XCTAssertEqual(try RepoIndexer.scan(root,includeMedia:true).files.map(\.path),["photo.png"])
    }
    func testProjectIdentityAndUnsupportedFolders() {
        XCTAssertEqual(ProjectIdentity.title(URL(fileURLWithPath:"/repo/drop-chat-voice-20260908")),"Whitespace Operator · build checkout")
        XCTAssertNotNil(ProjectIdentity.rejection(URL(fileURLWithPath:"/Applications")))
        XCTAssertNil(ProjectIdentity.rejection(URL(fileURLWithPath:"/Users/example/Screenshots")))
        XCTAssertNotNil(ProjectIdentity.rejection(URL(fileURLWithPath:"/Users/example/Example.app")))
        XCTAssertNil(ProjectIdentity.rejection(URL(fileURLWithPath:"/Users/example/my-project")))
    }
    func testGitRenamePathsAndPrivateExclusions() {
        let data=Data(" M src/a.py\0R  src/new name.swift\0src/old.swift\0?? .env.py\0 D src/gone.rs\0?? state/private.py\0".utf8)
        let changes=GitChanges.parse(data)
        XCTAssertEqual(changes.statuses.count,3)
        XCTAssertEqual(changes.statuses["src/new name.swift"],"R ")
        XCTAssertNil(changes.statuses["src/old.swift"]); XCTAssertEqual(changes.deleted,1)
    }
    func testLocalImportsAndTextOccurrencesAreBoundedAndDistinct() {
        let files=[SourceFile(path:"app/main.py",lines:1,bytes:1),SourceFile(path:"app/models.py",lines:1,bytes:1),SourceFile(path:"ui/view.ts",lines:1,bytes:1),SourceFile(path:"ui/store.ts",lines:1,bytes:1)]
        let py=ImportLinks.find(source:"from app.models import Model\nimport external",file:files[0],files:files)
        XCTAssertEqual(py.resolved,[1]); XCTAssertEqual(py.unresolved,["external"])
        let js=ImportLinks.find(source:"import { store } from './store';",file:files[2],files:files)
        XCTAssertEqual(js.resolved,[3])
        XCTAssertEqual(SymbolOccurrences.count("item",in:"item items item_count // item"),2)
        XCTAssertEqual(SymbolOccurrences.count(".*",in:"anything"),0)
    }
    func testPersonalProjectionRejectsOtherDeploymentsAndNestedRawPayloads() throws {
        XCTAssertThrowsError(try PersonalProjection.parse(["contract":"context-pack.v1","deployment_id":"work"]))
        let fixture:[String:Any]=["contract":"context-pack.v1","deployment_id":"personal","entities":[["entity_id":"a","display_name":"Learning","entity_type":"area"],["entity_id":"b","display_name":"Work code","entity_type":"repository"]],"claims":[["entity_id":"a","predicate":"raw","value":["connector":"private payload"]],["entity_id":"a","predicate":"goal","value":"Practice","status":"supported","evidence_ids":["e"]]],"evidence":[["evidence_id":"e","source_uri":"synthetic:note"]],"relationships":[["source_entity_id":"a","target_entity_id":"b","relationship_type":"related"]],"scope":["allowed_privacy":["public"]]]
        let p=try PersonalProjection.parse(fixture)
        XCTAssertEqual(p.areas.count,1); XCTAssertEqual(p.areas[0].claims,["goal: Practice [supported]"]); XCTAssertEqual(p.areas[0].sources,["synthetic:note"]); XCTAssertTrue(p.links.isEmpty)
    }
    func testPersonalStructuredClaimAllowlist() throws {
        let object:[String:Any]=["contract":"context-pack.v1","deployment_id":"personal","entities":[["entity_id":"a","entity_type":"area","display_name":"Synthetic"]],"claims":[["entity_id":"a","predicate":"goal","value":["label":"Learn Swift","status":"active","raw":"not allowed"],"status":"supported"]]]
        let p=try PersonalProjection.parse(object)
        XCTAssertEqual(p.areas[0].claims,["goal: label: Learn Swift · status: active [supported]"])
    }
    func testStalledGitTimesOutAndDoesNotFallBackToUnfilteredWalk() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-timeout-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let stub=root.appendingPathComponent("stall")
        try Data("#!/bin/sh\nexec /bin/sleep 2\n".utf8).write(to:stub)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:stub.path)
        let start=Date()
        XCTAssertThrowsError(try RepoIndexer.gitFiles(root,cancelled:{false},executable:stub,timeout:0.1)) {
            XCTAssertEqual($0 as? IndexError,.gitUnavailable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start),1)
        XCTAssertThrowsError(try RepoIndexer.gitFiles(root,cancelled:{true},executable:stub)) {
            XCTAssertEqual($0 as? IndexError,.cancelled)
        }
    }
    func testSquarifyConservesAreaAndDoesNotOverlap() {
        for count in [1,2,7,100,1000] {
            let weights=(0..<count).map { Double(1+($0*7919)%1000) }.sorted(by:>)
            let bounds=MapRect(10,20,1600,1000)
            let rects=Treemap.squarify(weights:weights,in:bounds)
            XCTAssertEqual(rects.count,count)
            XCTAssertEqual(rects.reduce(0) { $0+$1.area },bounds.area,accuracy:0.01)
            for (i,r) in rects.enumerated() {
                XCTAssertGreaterThan(r.w,0); XCTAssertGreaterThan(r.h,0)
                XCTAssertGreaterThanOrEqual(r.x,9.999); XCTAssertGreaterThanOrEqual(r.y,19.999)
                XCTAssertLessThanOrEqual(r.x+r.w,1610.001); XCTAssertLessThanOrEqual(r.y+r.h,1020.001)
                XCTAssertEqual(r.area/bounds.area,weights[i]/weights.reduce(0,+),accuracy:0.00001)
                for s in rects.dropFirst(i+1) {
                    let overlap=max(0,min(r.x+r.w,s.x+s.w)-max(r.x,s.x))*max(0,min(r.y+r.h,s.y+s.h)-max(r.y,s.y))
                    XCTAssertLessThan(overlap,0.001)
                }
            }
        }
    }
    func testNestedLayoutRetainsEveryFileDeterministically() {
        let files=(0..<300).map { SourceFile(path:"group\($0%7)/folder/file\($0).swift",lines:$0,bytes:$0*10) }
        let a=Treemap.layout(files), b=Treemap.layout(files)
        XCTAssertEqual(Set(a.tiles.map(\.fileID)),Set(files.indices)); XCTAssertEqual(a.tiles.count,files.count)
        XCTAssertEqual(a.tiles.map { $0.rect.x },b.tiles.map { $0.rect.x })
        XCTAssertTrue(a.tiles.allSatisfy { $0.rect.w>0 && $0.rect.h>0 })
    }
    func testSourcePolicyBlocksDataAndSensitivePaths() {
        for path in [".env",".env.py",".whitespace/graph/a.py","graph/data.py","state/private.swift","secrets.py","credential_store.py","node_modules/a.js","tmp/a.py","foo/../a.swift","/absolute.swift","record.json","notes.md","dork/main.swift","App.app/a.swift"] {
            XCTAssertFalse(SourcePolicy.allowed(path),path)
        }
        XCTAssertTrue(SourcePolicy.allowed("src/kernel/engine.py"))
        XCTAssertFalse(SourcePolicy.validateRoot(URL(fileURLWithPath:"/Users/example/.whitespace/graph")))
        XCTAssertTrue(SourcePolicy.validateRoot(URL(fileURLWithPath:"/Users/example/project/tmp/chosen-worktree")))
        XCTAssertFalse(SourcePolicy.validateRoot(URL(fileURLWithPath:"/Users/example/App.app/Contents/Resources")))
    }
    func testScannerCountsLinesSkipsSymlinksAndRejectsBinary() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("one\ntwo\n".utf8).write(to:root.appendingPathComponent("a.swift"))
        try Data("last line".utf8).write(to:root.appendingPathComponent("b.py"))
        try Data().write(to:root.appendingPathComponent("empty.rs"))
        try Data([1,0,2]).write(to:root.appendingPathComponent("binary.c"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.swift"),withDestinationURL:root.appendingPathComponent("a.swift"))
        let index=try RepoIndexer.scan(root)
        XCTAssertEqual(index.files.map(\.path),["a.swift","b.py","empty.rs"])
        XCTAssertEqual(index.lines,3)
        XCTAssertThrowsError(try RepoIndexer.readSource(root:root,path:"link.swift"))
        XCTAssertThrowsError(try RepoIndexer.scan(root,cancelled:{true}))
    }
    func testSymlinkedDirectoryCannotExposePrivateSource() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-link-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let outside=root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("private".utf8).write(to:outside.appendingPathComponent("a.swift"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("src"),withDestinationURL:outside)
        XCTAssertThrowsError(try RepoIndexer.readSource(root:root,path:"src/a.swift"))
        XCTAssertEqual(try RepoIndexer.scan(root).files.count,0)
    }
    func testGitIgnoreAppliedAndLargeFilesExcluded() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-git-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/git"); process.arguments=["init","-q",root.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        try Data("ignored.swift\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try Data("hidden\n".utf8).write(to:root.appendingPathComponent("ignored.swift"))
        try Data("visible".utf8).write(to:root.appendingPathComponent("good.swift"))
        try Data(repeating:65,count:RepoIndexer.maxFileBytes+10).write(to:root.appendingPathComponent("huge.swift"))
        let index=try RepoIndexer.scan(root)
        XCTAssertTrue(index.usesGitIgnore); XCTAssertEqual(index.files.map(\.path),["good.swift"])
    }
}

final class SourcePullTests:XCTestCase {
    func testReachingTopDoesNotCountScrollSpentInsideDocument() {
        var pull=SourcePull()
        XCTAssertFalse(pull.update(deltaY:180,atTop:false,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:30,atTop:true,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:30,atTop:true,isMomentum:false))
        XCTAssertTrue(pull.update(deltaY:12,atTop:true,isMomentum:false))
    }
    func testMomentumCancelsPartialExitGesture() {
        var pull=SourcePull()
        XCTAssertFalse(pull.update(deltaY:65,atTop:true,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:100,atTop:true,isMomentum:true))
        XCTAssertFalse(pull.update(deltaY:10,atTop:true,isMomentum:false))
        XCTAssertEqual(pull.distance,10)
    }
    func testReaderCanLoadBeyondStyledPreviewToLastLine() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-reader-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let content=String(repeating:"// Full source remains scrollable.\n",count:10_000)+"let finalLine = true\n"
        let expected=Data(content.utf8)
        try expected.write(to:root.appendingPathComponent("large.swift"))
        let actual=try RepoIndexer.readSource(root:root,path:"large.swift",limit:4*1024*1024)
        XCTAssertGreaterThan(actual.count,128_000)
        XCTAssertEqual(actual,expected)
        XCTAssertTrue(String(decoding:actual,as:UTF8.self).hasSuffix("let finalLine = true\n"))
    }
    func testOnlyDeliberateOverscrollAtTopExits() {
        var pull=SourcePull()
        XCTAssertFalse(pull.update(deltaY:100,atTop:false,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:100,atTop:true,isMomentum:true))
        XCTAssertFalse(pull.update(deltaY:40,atTop:true,isMomentum:false))
        XCTAssertTrue(pull.update(deltaY:33,atTop:true,isMomentum:false))
    }
    func testDownwardScrollResetsPull() {
        var pull=SourcePull()
        XCTAssertFalse(pull.update(deltaY:60,atTop:true,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:-5,atTop:true,isMomentum:false))
        XCTAssertFalse(pull.update(deltaY:20,atTop:true,isMomentum:false))
        XCTAssertEqual(pull.distance,20)
        pull.reset(); XCTAssertEqual(pull.distance,0)
    }
}
