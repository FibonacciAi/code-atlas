import AppKit
import AVFoundation
import AtlasCore

/// Runs only with --verify-preview-ui. It never loads saved roots or Personal.
final class PreviewVerification: NSObject, NSApplicationDelegate {
    private var window:NSWindow!
    private let map=MetalMap()
    private let state=NSTextField(labelWithString:"Isolated files · no personal content")
    private var files:[SourceFile]=[]
    private var root:URL!
    private var thumbnailsRoot:URL?
    private var statsTimer:Timer?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.appearance=NSAppearance(named:.darkAqua)
        do {
            root=try makeFiles()
            let index=try RepoIndexer.scan(root,includeMedia:true); files=index.files
            window=NSWindow(contentRect:NSRect(x:100,y:100,width:1080,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title="Code Atlas · Preview Verification"; window.isReleasedWhenClosed=false
            window.minSize=NSSize(width:850,height:600)
            let stack=NSStackView();stack.orientation = .vertical;stack.spacing=10;stack.edgeInsets=NSEdgeInsets(top:12,left:12,bottom:12,right:12);window.contentView=stack
            let title=NSTextField(labelWithString:"PREVIEW VERIFICATION · ISOLATED LOCAL FILES");title.font = .systemFont(ofSize:12,weight:.semibold);stack.addArrangedSubview(title)
            let bar=NSStackView();bar.spacing=8
            for (id,file) in files.enumerated() {
                let button=NSButton(title:(file.path as NSString).deletingPathExtension,target:self,action:#selector(openFixture(_:)));button.tag=id;bar.addArrangedSubview(button)
            }
            let reset=NSButton(title:"Reset map",target:self,action:#selector(reset));bar.addArrangedSubview(reset)
            let city=NSButton(title:"City",target:self,action:#selector(city));bar.addArrangedSubview(city)
            stack.addArrangedSubview(bar)
            let stress=NSButton(title:"Thumbnail grid · 90 generated images",target:self,action:#selector(showThumbnails));stack.addArrangedSubview(stress)
            let host=NSView();host.wantsLayer=true;host.layer?.backgroundColor=NSColor(calibratedWhite:0.04,alpha:1).cgColor
            map.translatesAutoresizingMaskIntoConstraints=false;host.addSubview(map)
            NSLayoutConstraint.activate([map.leadingAnchor.constraint(equalTo:host.leadingAnchor),map.trailingAnchor.constraint(equalTo:host.trailingAnchor),map.topAnchor.constraint(equalTo:host.topAnchor),map.bottomAnchor.constraint(equalTo:host.bottomAnchor)])
            stack.addArrangedSubview(host);host.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-24).isActive=true;host.heightAnchor.constraint(greaterThanOrEqualToConstant:450).isActive=true
            state.font = .systemFont(ofSize:11);state.textColor = .secondaryLabelColor;stack.addArrangedSubview(state)
            map.onCamera={ [weak self] value in self?.state.stringValue="Isolated files · zoom \(value)" }
            map.load(index,layout:Treemap.layout(files,sizing:.balanced))
            statsTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
                guard let self else {return}
                let activity=self.map.thumbnailActivity
                self.state.stringValue="Isolated files · zoom \(Int(self.map.zoom*100))% · requests \(activity.requests) · resident \(activity.resident) · pending \(activity.pending)"+(self.map.rendererError.map {" · Metal error: \($0)"} ?? "")
            }
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            let menu=NSMenu(), item=NSMenuItem();menu.addItem(item);let appMenu=NSMenu();item.submenu=appMenu
            appMenu.addItem(withTitle:"Quit Verification",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");NSApp.mainMenu=menu
        } catch {fputs("preview_verification_setup_failed\n",stderr);NSApp.terminate(nil)}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    @objc private func openFixture(_ button:NSButton) {
        if map.index?.root != root,let index=try? RepoIndexer.scan(root,includeMedia:true) {map.load(index,layout:Treemap.layout(index.files,sizing:.balanced))}
        map.openFile(button.tag)
    }
    @objc private func reset() {map.fit()}
    @objc private func city() {map.setCity(true)}
    @objc private func showThumbnails() {
        do {
            if thumbnailsRoot == nil {
                let folder=FileManager.default.temporaryDirectory.appendingPathComponent("CodeAtlas-Thumbnail-Verification-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                for id in 0..<90 {
                    let artwork=VerificationArtwork(frame:NSRect(x:0,y:0,width:640,height:420));artwork.number=id
                    let bitmap=artwork.bitmapImageRepForCachingDisplay(in:artwork.bounds)!
                    artwork.cacheDisplay(in:artwork.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(String(format:"Image-%02d.png",id)))
                }
                thumbnailsRoot=folder
            }
            let index=try RepoIndexer.scan(thumbnailsRoot!,includeMedia:true)
            map.setCity(false);map.load(index,layout:Treemap.layout(index.files,sizing:.equal))
        } catch {state.stringValue="Generated thumbnail setup failed"}
    }
    private func makeFiles() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("CodeAtlas-Verification-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let code="// SOURCE START\nimport Foundation\n"+(1...2400).map {"let value\($0) = \($0) // Verifier source line"}.joined(separator:"\n")+"\n// SOURCE END\n"
        try code.write(to:root.appendingPathComponent("Code.swift"),atomically:true,encoding:.utf8)
        try "<html><head><style>body{margin:0;padding:40px;background:#0d2035;color:#dff8ff;font:22px -apple-system}h1{color:#69dae8}.card{padding:28px;border:1px solid #3c6b85;border-radius:18px}</style></head><body><h1>HTML preview is visible</h1><input placeholder='Focus here then press Escape'><div class='card'>Local static content. Preview and Source must both work.</div><div style='height:1800px'>Scroll through this complete page.</div><p>HTML END</p></body></html>".write(to:root.appendingPathComponent("HTML.html"),atomically:true,encoding:.utf8)
        try "<!doctype html><html><head><title>App shell</title></head><body><div id='root'></div><script src='/assets/app.js'></script></body></html>".write(to:root.appendingPathComponent("App-shell.html"),atomically:true,encoding:.utf8)
        try ("DOCUMENT START\n"+String(repeating:"A local test document — text and symbols ✓\n",count:200)+"DOCUMENT END\n").write(to:root.appendingPathComponent("Document.txt"),atomically:true,encoding:.utf8)
        try ("# Markdown preview\n\n**Readable inside Atlas** with `inline code`.\n\n"+String(repeating:"A complete paragraph with preserved text — ✓\n\n",count:200)+"MARKDOWN END\n").write(to:root.appendingPathComponent("Markdown.md"),atomically:true,encoding:.utf8)
        let artwork=VerificationArtwork(frame:NSRect(x:0,y:0,width:640,height:420))
        let bitmap=artwork.bitmapImageRepForCachingDisplay(in:artwork.bounds)!;artwork.cacheDisplay(in:artwork.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("Image.png"))
        try artwork.dataWithPDF(inside:artwork.bounds).write(to:root.appendingPathComponent("PDF.pdf"))
        var wave=Data();func text(_ s:String){wave.append(contentsOf:s.utf8)}
        func number<T:FixedWidthInteger>(_ n:T){var v=n.littleEndian;withUnsafeBytes(of:&v){wave.append(contentsOf:$0)}}
        let length:UInt32=88_200;text("RIFF");number(length+36);text("WAVEfmt ");number(UInt32(16));number(UInt16(1));number(UInt16(1));number(UInt32(22_050));number(UInt32(44_100));number(UInt16(2));number(UInt16(16));text("data");number(length)
        for sample in 0..<Int(length/2) {
            let time=Double(sample)/22_050, envelope=min(1,min(time/0.02,(2-time)/0.02))
            number(Int16(sin(time*440*2*Double.pi)*3_000*max(0,envelope)))
        }
        try wave.write(to:root.appendingPathComponent("Audio.wav"))
        try makeMovie(root.appendingPathComponent("Video.mov"))
        return root
    }
    private func makeMovie(_ url:URL) throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:200])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:200])
        writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
        let deadline=Date().addingTimeInterval(6)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData && Date()<deadline {Thread.sleep(forTimeInterval:0.005)}
            guard input.isReadyForMoreMediaData, let pool=adaptor.pixelBufferPool else {break}
            var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)
            guard let buffer else {continue};CVPixelBufferLockBaseAddress(buffer,[])
            let bytes=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<200 {for x in 0..<320 {let i=y*stride+x*4;bytes[i]=255;bytes[i+1]=UInt8(20+frame*3);bytes[i+2]=UInt8(100+x/3);bytes[i+3]=UInt8(100+y/2)}}
            CVPixelBufferUnlockBaseAddress(buffer,[]);adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:15))
        }
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()};_ = done.wait(timeout:.now()+6)
    }
}
private final class VerificationArtwork:NSView {
    var number:Int?
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedRed:0.04,green:0.11,blue:0.18,alpha:1).setFill();bounds.fill()
        NSColor.systemTeal.setFill();NSBezierPath(roundedRect:NSRect(x:40,y:40,width:260,height:230),xRadius:20,yRadius:20).fill()
        NSColor.systemIndigo.setFill();NSBezierPath(roundedRect:NSRect(x:320,y:40,width:280,height:230),xRadius:20,yRadius:20).fill()
        ((number.map {"ATLAS IMAGE \($0) ↑"} ?? "ATLAS PREVIEW CHECK") as NSString).draw(at:NSPoint(x:42,y:320),withAttributes:[.font:NSFont.systemFont(ofSize:28,weight:.bold),.foregroundColor:NSColor.white])
    }
}
