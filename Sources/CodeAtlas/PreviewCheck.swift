import AppKit
import AtlasCore

func checkPreviewLayout() {
    let app=NSApplication.shared; app.appearance=NSAppearance(named:.darkAqua)
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    let host=NSView(frame:NSRect(x:0,y:0,width:900,height:700)); window.contentView=host
    let reader=ImmersiveSource(path:"check.swift"); reader.frame=host.bounds;host.addSubview(reader)
    reader.show("import Foundation\n"+String(repeating:"let value = 42\n",count:300));host.layoutSubtreeIfNeeded()
    print("reader_children=\(reader.subviews.map {String(describing:type(of:$0))+":"+NSStringFromRect($0.frame)})")
    reader.removeFromSuperview()
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("atlas-preview-check-"+UUID().uuidString)
    try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let file=root.appendingPathComponent("check.html");try! "<h1>Preview check</h1>".write(to:file,atomically:true,encoding:.utf8)
    let preview=ContentPreview(url:file,kind:.html);preview.frame=host.bounds;host.addSubview(preview);host.layoutSubtreeIfNeeded()
    print("preview_children=\(preview.subviews.map {String(describing:type(of:$0))+":"+NSStringFromRect($0.frame)})")
    RunLoop.main.run(until:Date().addingTimeInterval(2))
    print("preview_layout_check_complete=true")
}
