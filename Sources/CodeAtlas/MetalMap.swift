import AppKit
import MetalKit
import AtlasCore

private struct GPUInstance { var rect: SIMD4<Float>; var color: SIMD4<Float>; var extra: SIMD4<Float> }
private struct GPUCamera { var view: SIMD4<Float>; var pose: SIMD4<Float> }
private struct GPUThumbnail { var rect: SIMD4<Float>; var image: SIMD4<Float> }

final class MapOverlay: NSView {
    weak var map: MetalMap?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { map?.drawLabels() }
}

final class MetalMap: MTKView, MTKViewDelegate {
    var index: RepositoryIndex?
    var layoutData = MapLayout(tiles: [], folders: [])
    var onSelect: ((Int) -> Void)?
    var onPreviewSelection: ((Int) -> Void)?
    var onCamera: ((String) -> Void)?
    var onHistory: ((Bool) -> Void)?
    var colorMode=0 { didSet { rebuild(); invalidate() } }
    var gitStatuses:[String:String]=[:] { didSet { rebuild(); invalidate() } }
    var visibleMatches:Set<Int>? { didSet { if visibleMatches != oldValue { rebuild(); invalidate() } } }
    var previewProvider:((SourceFile)->String)?
    private var previewCache:[Int:String]=[:]
    private var previewPending=Set<Int>()
    private var previewGeneration=UUID()
    private var cameraAnimation:Timer?
    private var history:[(CGPoint,CGFloat)]=[]
    var relatedFiles=Set<Int>() {didSet {if relatedFiles != oldValue {rebuild();invalidate()}}}
    var selected: Int? { didSet { if selected != oldValue { rebuild(); invalidate() } } }
    var query = "" { didSet { if query != oldValue { rebuild(); invalidate() } } }
    var selectedSource = "" { didSet { overlay.needsDisplay = true } }
    var center = CGPoint(x:800,y:500)
    var zoom: CGFloat = 0.5
    var tilt: CGFloat = 0
    private var targetTilt: CGFloat = 0
    private var cityEnabled=false
    private var cityOverviewZoom:CGFloat=0.5
    private var animation: Timer?
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var thumbnailPipeline: MTLRenderPipelineState!
    private var depth: MTLDepthStencilState!
    private var instances: MTLBuffer?
    private var count = 0
    private let overlay = MapOverlay()
    private var dragOrigin: CGPoint?
    private var didDrag = false
    private var lastSize = CGSize.zero
    private var lastMotion:TimeInterval=0
    private var settleWork:DispatchWorkItem?
    private var moving:Bool {ProcessInfo.processInfo.systemUptime-lastMotion<0.18}
    private func markMotion() {
        lastMotion=ProcessInfo.processInfo.systemUptime
        settleWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.invalidate() }; settleWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    private var contentPreview:ContentPreview?
    private lazy var thumbnails = MapThumbnails(device: device)
    // Diagnostic counts are used only by the isolated generated-file verifier.
    var thumbnailActivity: (requests: Int, resident: Int, pending: Int) {
        (thumbnails.requestCount, thumbnails.residentCount, thumbnails.pendingCount)
    }
    private var reader:ImmersiveSource?
    private var readerGeneration=UUID()
    private var readerReturn:(CGPoint,CGFloat)?
    private var readerOrigin=CGRect.zero
    private var externalReaderOrigin:CGRect?
    private var readerFromGraph=false
    var onGraphReaderClose:(()->Void)?
    var hasOpenReader:Bool {reader != nil || contentPreview != nil}
    func closeReader() {dismissReader(animated:true)}
    private var readerFileID:Int?
    private var previewNavigation:PreviewNavigation?
    private var gestureGate=PreviewGestureGate()
    private func overlayFrame(_ rect:CGRect)->CGRect {convert(rect,to:superview ?? self)}
    private func usableOrigin(_ rect:CGRect)->CGRect {
        if !rect.isNull && !rect.isInfinite && rect.width>20 && rect.height>20 {return rect}
        return CGRect(x:bounds.midX-90,y:bounds.midY-60,width:180,height:120)
    }
    var gpuName: String { device?.name ?? "Metal unavailable" }
    var rendererError: String?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame:.zero, device:MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor=MTLClearColor(red:0.035,green:0.048,blue:0.067,alpha:1)
        isPaused=true; enableSetNeedsDisplay=true; preferredFramesPerSecond=120
        delegate=self; overlay.map=self; addSubview(overlay)
        thumbnails.onChange = { [weak self] in self?.needsDisplay = true }
        setAccessibilityLabel("Code treemap. Drag to pan. Scroll down into a file; scroll up to zoom out. Pinch to zoom. Double click opens a file. Escape resets the view.")
        do { try configure() } catch { rendererError=error.localizedDescription }
    }
    required init(coder: NSCoder) { fatalError() }
    private func configure() throws {
        guard let device, let queue=device.makeCommandQueue() else { throw NSError(domain:"Metal is unavailable on this Mac",code:1) }
        self.queue=queue
        let library=try device.makeLibrary(source: Self.shader, options:nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"vertexMap")
        descriptor.fragmentFunction=library.makeFunction(name:"fragmentMap")
        descriptor.colorAttachments[0].pixelFormat=colorPixelFormat
        descriptor.depthAttachmentPixelFormat=depthStencilPixelFormat
        pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        descriptor.vertexFunction=library.makeFunction(name:"vertexThumbnail")
        descriptor.fragmentFunction=library.makeFunction(name:"fragmentThumbnail")
        let blend=descriptor.colorAttachments[0]!
        blend.isBlendingEnabled=true
        blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one; blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        thumbnailPipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let ds=MTLDepthStencilDescriptor(); ds.depthCompareFunction = .lessEqual; ds.isDepthWriteEnabled=true
        depth=device.makeDepthStencilState(descriptor:ds)
    }
    override func layout() {
        super.layout(); overlay.frame=bounds
        if let reader { reader.frame=overlayFrame(bounds.insetBy(dx:8,dy:8)) }
        contentPreview?.frame=overlayFrame(bounds.insetBy(dx:8,dy:8))
        if lastSize == .zero && bounds.width > 10 { fit() }
        lastSize=bounds.size; invalidate()
    }
    func load(_ index: RepositoryIndex, layout: MapLayout) {
        dismissReader(animated:false)
        cameraAnimation?.invalidate(); history=[]; onHistory?(false)
        previewGeneration=UUID(); previewCache=[:]; previewPending=[]; thumbnails.clear(); visibleMatches=nil
        self.index=index; self.layoutData=layout; selected=nil; selectedSource=""; rebuild(); fit(); history=[]; onHistory?(false)
    }
    func clear() { dismissReader(animated:false); previewGeneration=UUID(); previewCache=[:]; previewPending=[]; thumbnails.clear(); index=nil; layoutData=MapLayout(tiles:[],folders:[]); instances=nil; count=0; selected=nil; history=[]; onHistory?(false); invalidate() }
    func fly(to point:CGPoint, scale:CGFloat, remember:Bool=true) {
        dismissReader(animated:false)
        cameraAnimation?.invalidate()
        if remember { history.append((center,zoom)); if history.count>40 { history.removeFirst() }; onHistory?(true) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { center=point; zoom=scale; tilt=cityTilt(at:scale); invalidate(); return }
        let origin=center, oldZoom=zoom, oldTilt=tilt, destinationTilt=cityTilt(at:scale), start=ProcessInfo.processInfo.systemUptime
        cameraAnimation=Timer(timeInterval:1/120,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t=min(1,(ProcessInfo.processInfo.systemUptime-start)/0.24), ease=t*t*(3-2*t)
            self.center=CGPoint(x:origin.x+(point.x-origin.x)*ease,y:origin.y+(point.y-origin.y)*ease)
            self.zoom=exp(log(oldZoom)+(log(scale)-log(oldZoom))*ease)
            self.tilt=oldTilt+(destinationTilt-oldTilt)*ease; self.invalidate()
            if t>=1 { timer.invalidate() }
        }
        if let cameraAnimation { RunLoop.main.add(cameraAnimation,forMode:.common) }
    }
    func goBack() { guard let last=history.popLast() else {return}; fly(to:last.0,scale:last.1,remember:false); onHistory?(!history.isEmpty) }
    func focusFolder(_ path:String) {
        if path.isEmpty { fit(); return }
        guard let r=layoutData.folders.first(where:{$0.path==path})?.rect else { return }
        fly(to:CGPoint(x:r.x+r.w/2,y:r.y+r.h/2),scale:min(80,max(0.02,min((bounds.width-70)/r.w,(bounds.height-100)/r.h))))
    }
    func fit() {
        targetTilt=cityEnabled ? 0.98 : 0
        let a=targetTilt*0.33
        let width=1600*cos(a)+1000*sin(a)
        let height=(1600*sin(a)+1000*cos(a))*cos(targetTilt)+120*sin(targetTilt)
        cityOverviewZoom=max(0.02,min((bounds.width-70)/width,(bounds.height-100)/height))
        fly(to:CGPoint(x:800,y:500),scale:cityOverviewZoom)
    }
    func focus(_ id: Int) {
        guard let tile=layoutData.tiles.first(where:{$0.fileID == id}) else { return }
        fly(to:CGPoint(x:tile.rect.x+tile.rect.w/2,y:tile.rect.y+tile.rect.h/2),scale:min(80,max(0.02,min((bounds.width-100)/tile.rect.w,(bounds.height-100)/tile.rect.h))))
        selected=id; invalidate()
    }
    func setCity(_ city: Bool) {
        cityEnabled=city
        targetTilt=city ? 0.98 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { tilt=targetTilt; fit(); return }
        animation?.invalidate()
        fit()
    }
    private func palette(_ group: String) -> SIMD3<Float> {
        let colors: [SIMD3<Float>] = [SIMD3(0.21,0.69,0.64),SIMD3(0.35,0.53,0.90),SIMD3(0.67,0.48,0.83),SIMD3(0.86,0.57,0.32),SIMD3(0.62,0.75,0.40),SIMD3(0.33,0.65,0.82),SIMD3(0.84,0.40,0.54)]
        let hash=group.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return colors[Int(hash % UInt64(colors.count))]
    }
    func rebuild() {
        guard let index, let device else { return }
        let instances=layoutData.tiles.map { tile -> GPUInstance in
            let file=index.files[tile.fileID]; var color=palette(tile.group)
            if colorMode==1 { color=palette(file.language) }
            if colorMode==2 {
                let status=gitStatuses[file.path] ?? ""
                color=status.isEmpty ? SIMD3(0.17,0.23,0.29) : status.contains("?") || status.contains("A") ? SIMD3(0.25,0.82,0.55) : status.contains("R") ? SIMD3(0.87,0.42,0.68) : SIMD3(0.96,0.67,0.27)
            }
            let isMatch=(visibleMatches?.contains(tile.fileID) ?? true) && (query.isEmpty || file.path.localizedCaseInsensitiveContains(query))
            if !isMatch { color *= 0.20 }
            color *= 0.72
            if relatedFiles.contains(tile.fileID) {color=SIMD3(0.35,0.82,0.64)}
            if selected == tile.fileID { color=SIMD3(0.50,0.86,0.92) }
            let r=tile.rect
            return GPUInstance(rect:SIMD4(Float(r.x),Float(r.y),Float(r.w),Float(r.h)),color:SIMD4(color,1),extra:SIMD4(Float(tile.height),0,0,0))
        }
        count=instances.count
        self.instances=instances.isEmpty ? nil : device.makeBuffer(bytes:instances,length:instances.count*MemoryLayout<GPUInstance>.stride,options:.storageModeShared)
    }
    func invalidate() {
        needsDisplay=true; overlay.needsDisplay=true
        onCamera?(String(format:"%.0f%%",zoom*100))
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidate() }
    func draw(in view: MTKView) {
        guard pipeline != nil, let descriptor=currentRenderPassDescriptor, let drawable=currentDrawable, let command=queue.makeCommandBuffer() else { return }
        let images=thumbnailInstances()
        thumbnails.encodeUploads(command)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else {return}
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        var camera=GPUCamera(view:SIMD4(Float(bounds.width),Float(bounds.height),Float(zoom),Float(tilt)),pose:SIMD4(Float(center.x),Float(center.y),0,0))
        encoder.setVertexBytes(&camera,length:MemoryLayout<GPUCamera>.stride,index:1)
        if let instances, count > 0 {
            encoder.setVertexBuffer(instances,offset:0,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:18,instanceCount:count)
        }
        if !images.isEmpty, let texture=thumbnails.texture {
            encoder.setRenderPipelineState(thumbnailPipeline)
            images.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:0) }
            encoder.setFragmentTexture(texture,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:images.count)
        }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    private func thumbnailInstances() -> [GPUThumbnail] {
        guard let index, tilt<0.08 else {thumbnails.retainVisible([]);return []}
        // Pin the entire drawable set before requesting anything. Incoming work
        // from an old viewport can only replace an offscreen, older slot.
        let tiles=visibleDetailTiles().filter { [.image,.video,.pdf].contains(index.files[$0.fileID].kind) }
        thumbnails.retainVisible(tiles.map(\.fileID))
        var images:[GPUThumbnail]=[]
        for tile in tiles {
            guard let image=thumbnails.image(for:tile.fileID) else {
                if !moving {thumbnails.request(tile.fileID,index:index)}
                continue
            }
            let r=tile.rect
            // Gradual LOD thresholds retain already loaded images across small
            // reversals instead of replacing them with solid color each event.
            let sizeFade=min(1,max(0,(r.w*zoom-72)/36))*min(1,max(0,(r.h*zoom-32)/52))
            let flatFade=min(1,max(0,(0.08-tilt)/0.06))
            let matched=(visibleMatches?.contains(tile.fileID) ?? true) && (query.isEmpty || index.files[tile.fileID].path.localizedCaseInsensitiveContains(query))
            let opacity=Float(sizeFade*flatFade)*(matched ? 1 : 0.18)
            guard opacity>0 else {continue}
            images.append(GPUThumbnail(rect:SIMD4(Float(r.x),Float(r.y),Float(r.w),Float(r.h)),image:SIMD4(image.aspect,Float(image.slot),opacity,Float(tile.height))))
        }
        return images
    }
    private func visibleDetailTiles() -> [MapTile] {
        layoutData.tiles.filter { tile in
            if tile.rect.w*zoom<72 || tile.rect.h*zoom<24 {return false}
            if tilt<0.01 {let p=projected(tile.rect.x,tile.rect.y);return CGRect(x:p.x,y:p.y,width:tile.rect.w*zoom,height:tile.rect.h*zoom).intersects(bounds)}
            let p=polygon(tile);let xs=p.map(\.x),ys=p.map(\.y)
            return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).intersects(bounds)
        }.sorted {
            let left=$0.fileID == selected ? Double.greatestFiniteMagnitude : $0.rect.area
            let right=$1.fileID == selected ? Double.greatestFiniteMagnitude : $1.rect.area
            return left == right ? $0.fileID < $1.fileID : left > right
        }.prefix(70).map {$0}
    }
    func projected(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        let a=Double(tilt)*0.33; let dx=x-center.x, dy=y-center.y
        let rx=dx*cos(a)-dy*sin(a), ry=dx*sin(a)+dy*cos(a)
        return CGPoint(x:bounds.width/2+rx*zoom,y:bounds.height/2+(ry*cos(tilt)-z*sin(tilt))*zoom)
    }
    private func unproject(_ point: CGPoint, height:CGFloat=0) -> CGPoint {
        let rx=(point.x-bounds.width/2)/zoom, ry=((point.y-bounds.height/2)/zoom+height*tilt*sin(tilt))/max(0.2,cos(tilt))
        let a=tilt*0.33
        return CGPoint(x:center.x+rx*cos(a)+ry*sin(a),y:center.y-rx*sin(a)+ry*cos(a))
    }
    func polygon(_ tile: MapTile) -> [CGPoint] {
        let r=tile.rect; let z=tile.height*Double(tilt)
        return [projected(r.x,r.y,z),projected(r.x+r.w,r.y,z),projected(r.x+r.w,r.y+r.h,z),projected(r.x,r.y+r.h,z)]
    }
    private func hit(_ point: CGPoint) -> Int? {
        var winner: (Int,Double)?
        for tile in layoutData.tiles {
            if tilt<0.01 {
                let world=unproject(point), r=tile.rect
                if world.x>=r.x && world.x<=r.x+r.w && world.y>=r.y && world.y<=r.y+r.h {return tile.fileID}
                continue
            }
            let p=polygon(tile)
            guard point.x >= p.map(\.x).min()!, point.x <= p.map(\.x).max()!, point.y >= p.map(\.y).min()!, point.y <= p.map(\.y).max()! else {continue}
            let path=NSBezierPath(); path.move(to:p[0]); p.dropFirst().forEach{path.line(to:$0)}; path.close()
            if path.contains(point) {
                let a=Double(tilt)*0.33, r=tile.rect
                let d = -((r.x+r.w/2-center.x)*sin(a)+(r.y+r.h/2-center.y)*cos(a))*sin(tilt)-tile.height*Double(tilt)*cos(tilt)
                if winner == nil || d < winner!.1 { winner=(tile.fileID,d) }
            }
        }
        return winner?.0
    }
    override func mouseDown(with event: NSEvent) { cameraAnimation?.invalidate(); window?.makeFirstResponder(self); dragOrigin=convert(event.locationInWindow,from:nil); didDrag=false }
    override func mouseDragged(with event: NSEvent) {
        markMotion()
        let point=convert(event.locationInWindow,from:nil)
        guard let old=dragOrigin else { return }
        if hypot(point.x-old.x,point.y-old.y)>2 { didDrag=true }
        let p=unproject(point), o=unproject(old); center.x -= p.x-o.x; center.y -= p.y-o.y
        dragOrigin=point; invalidate()
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin=nil }
        guard !didDrag, let id=hit(convert(event.locationInWindow,from:nil)) else { return }
        selected=id; onSelect?(id)
        if event.clickCount == 2 { openFile(id) }
    }
    private func cityTilt(at scale:CGFloat) -> CGFloat {
        guard cityEnabled else {return 0}
        let t=min(1,max(0,(scale/max(0.015,cityOverviewZoom)-1.3)/4))
        return 0.98*(1-t*t*(3-2*t))
    }
    private func scale(_ factor: CGFloat, at point: CGPoint, allowEntry:Bool=true) {
        guard reader == nil, contentPreview == nil else {return}
        markMotion()
        cameraAnimation?.invalidate()
        let roof=tilt<0.01 ? 0 : (hit(point).flatMap {id in layoutData.tiles.first(where:{$0.fileID==id})?.height} ?? 0)
        let before=unproject(point,height:roof); zoom=min(80,max(0.015,zoom*factor))
        if cityEnabled {
            animation?.invalidate()
            tilt=cityTilt(at:zoom)
        }
        let after=unproject(point,height:roof)
        center.x += before.x-after.x; center.y += before.y-after.y; invalidate()
        if factor>1 && allowEntry { considerReader(at:point) }
    }
    func openFile(_ id:Int) {considerReader(at:CGPoint(x:bounds.midX,y:bounds.midY),forceID:id)}
    func openFileFromGraph(_ id:Int, rect:CGRect) {
        guard !hasOpenReader else {return}
        externalReaderOrigin=rect;openFile(id);externalReaderOrigin=nil
    }
    func suspendInteraction() {
        cameraAnimation?.invalidate();animation?.invalidate()
        contentPreview?.pausePlayback()
    }
    private func considerReader(at point:CGPoint, forceID:Int?=nil) {
        guard reader == nil, contentPreview == nil, zoom>1.4 || forceID != nil, let index, let id=forceID ?? hit(point),
              visibleMatches?.contains(id) ?? true,
              let tile=layoutData.tiles.first(where:{$0.fileID==id}) else {return}
        let corners=polygon(tile), xs=corners.map(\.x), ys=corners.map(\.y)
        let r=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        let visible=r.intersection(bounds)
        guard forceID != nil || (visible.width>min(380,bounds.width*0.6) && visible.height>min(260,bounds.height*0.5)) || (zoom>=70 && visible.width>12 && visible.height>12) else {return}
        cameraAnimation?.invalidate(); if selected != id {selectedSource=""}; selected=id; onPreviewSelection?(id)
        readerReturn=(center,forceID == nil ? zoom*0.72 : zoom)
        readerFromGraph=externalReaderOrigin != nil
        readerOrigin=usableOrigin(externalReaderOrigin ?? visible); externalReaderOrigin=nil; readerFileID=id
        if index.files[id].kind != .code {
            guard let url=try? RepoIndexer.validatedURL(root:index.root,path:index.files[id].path) else {return}
            let preview=ContentPreview(url:url,kind:index.files[id].kind,returnTitle:readerFromGraph ? "Graph":"Map")
            contentPreview=preview
            preview.onClose={ [weak self] in self?.dismissReader(animated:true) }
            presentPreview(preview,position:{[weak preview] in preview?.scrollPosition ?? .canvas},responder:{[weak preview] in preview?.preferredResponder})
            return
        }
        let view=ImmersiveSource(path:index.files[id].path,returnTitle:readerFromGraph ? "Graph":"Map"), generation=UUID()
        readerGeneration=generation; reader=view
        view.onExit={ [weak self] in self?.dismissReader(animated:true) }
        presentPreview(view,position:{[weak view] in .document(atTop:(view?.scroll.contentView.bounds.minY ?? 0)<=1)},responder:{[weak view] in view?.text})
        let provider=previewProvider
        DispatchQueue.global(qos:.userInitiated).async { [weak self,weak view] in
            let content=provider?(index.files[id]) ?? (try? RepoIndexer.readSource(root:index.root,path:index.files[id].path,limit:4*1024*1024)).map {String(decoding:$0,as:UTF8.self)}
            DispatchQueue.main.async {
                guard let self, self.readerGeneration==generation, let view else {return}
                view.show(content ?? "Source could not be opened. Return to the map and refresh.")
            }
        }
    }
    private func presentPreview(_ view:NSView,position:@escaping()->PreviewScrollPosition,responder:@escaping()->NSResponder?) {
        // Lay out once at reading size. Core Animation moves the composited surface,
        // avoiding repeated WebKit/PDF/player layout during the tile expansion.
        view.frame=overlayFrame(bounds.insetBy(dx:8,dy:8))
        (superview ?? self).addSubview(view);view.layoutSubtreeIfNeeded()
        previewNavigation=PreviewNavigation(view:view,position:position,prepare:{[weak view] event in
            (view as? ContentPreview)?.prepareForScroll(event)
        },progress:{[weak self,weak view] progress in
            guard let self,let view else {return}
            self.reader?.setPullProgress(progress)
            guard let layer=view.layer else {return}
            let s=CGFloat(1-progress*0.025)
            CATransaction.begin();CATransaction.setDisableActions(true)
            var transform=CATransform3DMakeScale(s,s,1)
            transform.m41=(0.5-layer.anchorPoint.x)*view.bounds.width*(1-s)
            transform.m42=(0.5-layer.anchorPoint.y)*view.bounds.height*(1-s)
            layer.transform=transform;layer.opacity=Float(1-progress*0.06)
            CATransaction.commit()
        },exit:{[weak self] in self?.dismissReader(animated:true)})
        animatePreview(view,tileRect:readerOrigin,opening:true) { [weak self,weak view] in
            guard let self,let view,(self.reader === view || self.contentPreview === view) else {return}
            (view as? ContentPreview)?.didPresent()
            if let target=responder() {self.window?.makeFirstResponder(target)}
        }
    }
    private func animatePreview(_ view:NSView,tileRect:CGRect,opening:Bool,completion:@escaping()->Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,let layer=view.layer,let parent=view.superview else {completion();return}
        let tile=parent.convertToLayer(overlayFrame(usableOrigin(tileRect)))
        let scale=CATransform3DMakeScale(tile.width/max(1,view.bounds.width),tile.height/max(1,view.bounds.height),1)
        let tilePosition=CGPoint(x:tile.minX+tile.width*layer.anchorPoint.x,y:tile.minY+tile.height*layer.anchorPoint.y)
        let transform=CABasicAnimation(keyPath:"transform")
        transform.fromValue=NSValue(caTransform3D:opening ? scale : (layer.presentation()?.transform ?? layer.transform))
        transform.toValue=NSValue(caTransform3D:opening ? CATransform3DIdentity : scale)
        let move=CABasicAnimation(keyPath:"position")
        move.fromValue=NSValue(point:opening ? tilePosition : (layer.presentation()?.position ?? layer.position))
        move.toValue=NSValue(point:opening ? layer.position : tilePosition)
        let opacity=CABasicAnimation(keyPath:"opacity")
        opacity.fromValue=opening ? 0.15 : (layer.presentation()?.opacity ?? layer.opacity)
        opacity.toValue=opening ? 1 : 0
        let group=CAAnimationGroup();group.animations=[transform,move,opacity];group.duration=opening ? 0.24 : 0.20
        group.timingFunction=CAMediaTimingFunction(name:opening ? .easeOut : .easeInEaseOut)
        group.isRemovedOnCompletion=opening;group.fillMode = .forwards
        CATransaction.begin();CATransaction.setCompletionBlock(completion)
        layer.add(group,forKey:"atlas-preview-transition")
        CATransaction.commit()
    }
    private func dismissReader(animated:Bool) {
        guard let view=(reader as NSView?) ?? contentPreview else {return}
        previewNavigation=nil;contentPreview?.stopPreview()
        contentPreview=nil;reader=nil; readerGeneration=UUID()
        gestureGate.exit(at:ProcessInfo.processInfo.systemUptime)
        if let previous=readerReturn { center=previous.0; zoom=previous.1; tilt=cityTilt(at:zoom) }; readerReturn=nil
        if !readerFromGraph,let id=readerFileID, let tile=layoutData.tiles.first(where:{$0.fileID==id}) {
            let corners=polygon(tile), xs=corners.map(\.x), ys=corners.map(\.y)
            readerOrigin=usableOrigin(CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).intersection(bounds))
        }
        let returningToGraph=readerFromGraph;readerFromGraph=false
        if returningToGraph {onGraphReaderClose?()} else {window?.makeFirstResponder(self)}
        invalidate()
        if !animated {view.layer?.removeAllAnimations();view.removeFromSuperview();return}
        animatePreview(view,tileRect:readerOrigin,opening:false) {view.removeFromSuperview()}
    }
    override func scrollWheel(with event: NSEvent) {
        let allowEntry=gestureGate.accepts(deltaY:Double(event.scrollingDeltaY),isMomentum:!event.momentumPhase.isEmpty,phaseBegan:event.phase == .began,isUnphased:event.phase.isEmpty,at:ProcessInfo.processInfo.systemUptime)
        scale(CGFloat(MapZoom.factor(deltaY:Double(event.scrollingDeltaY))),at:convert(event.locationInWindow,from:nil),allowEntry:allowEntry)
    }
    override func magnify(with event: NSEvent) { scale(1+event.magnification,at:convert(event.locationInWindow,from:nil)) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if reader != nil || contentPreview != nil {dismissReader(animated:true)} else {fit()}
        case 123: center.x -= 40/zoom; invalidate()
        case 124: center.x += 40/zoom; invalidate()
        case 125: center.y += 40/zoom; invalidate()
        case 126: center.y -= 40/zoom; invalidate()
        default: super.keyDown(with:event)
        }
    }
    func drawLabels() {
        guard let index else { return }
        NSGraphicsContext.saveGraphicsState();defer {NSGraphicsContext.restoreGraphicsState()}
        NSBezierPath(rect:bounds).addClip()
        let labelAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white.withAlphaComponent(0.92)]
        var drawn=0; var occupied:[CGRect]=[]
        if tilt < 0.05 {
            for folder in layoutData.folders where folder.depth == 0 || (folder.depth < 3 && zoom > 1.8) {
                let p=projected(folder.rect.x,folder.rect.y)
                if folder.rect.w*zoom > 90 && bounds.contains(p) && drawn < 60 {
                    let labelRect=CGRect(x:p.x,y:p.y-2,width:min(folder.rect.w*zoom,CGFloat(folder.name.count*7+8)),height:15)
                    if !occupied.contains(where:{$0.intersects(labelRect)}) { (folder.name as NSString).draw(in:labelRect,withAttributes:labelAttrs); occupied.append(labelRect); drawn += 1 }
                }
            }
        }
        let candidates=visibleDetailTiles()
        var previewsDrawn=0
        for tile in candidates.prefix(70) {
            let p=polygon(tile)[0]; let file=index.files[tile.fileID]
            let rect=CGRect(x:p.x+5,y:p.y+4,width:max(1,tile.rect.w*zoom-10),height:18)
            var attrs=labelAttrs
            if selected == tile.fileID { attrs[.foregroundColor]=NSColor(calibratedWhite:0.08,alpha:1) }
            let paragraph=NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; attrs[.paragraphStyle]=paragraph
            if !occupied.contains(where:{$0.intersects(rect)}) { (URL(fileURLWithPath:file.path).lastPathComponent as NSString).draw(in:rect,withAttributes:attrs); occupied.append(rect) }
            let visibleRect=CGRect(x:p.x,y:p.y,width:tile.rect.w*zoom,height:tile.rect.h*zoom).intersection(bounds)
            if [ContentKind.code,.html].contains(file.kind) && tilt < 0.05 && zoom>1.4 && visibleRect.width>240 && visibleRect.height>100 && previewsDrawn<4 && (visibleMatches?.contains(tile.fileID) ?? true) {
                previewsDrawn += 1
                let content=selected==tile.fileID && !selectedSource.isEmpty ? selectedSource : previewCache[tile.fileID]
                guard let content else { if !moving {requestPreview(tile.fileID)}; continue }
                NSGraphicsContext.saveGraphicsState()
                let sourceRect=CGRect(x:p.x+6,y:p.y+26,width:tile.rect.w*zoom-12,height:tile.rect.h*zoom-32)
                let panel=sourceRect.intersection(bounds)
                NSColor(calibratedRed:0.04,green:0.065,blue:0.09,alpha:0.94).setFill()
                NSBezierPath(roundedRect:panel,xRadius:5,yRadius:5).fill()
                NSBezierPath(rect:panel.insetBy(dx:8,dy:6)).addClip()
                let size=min(16,max(10,zoom*0.7))
                (content as NSString).draw(in:sourceRect.insetBy(dx:10,dy:8),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.regular),.foregroundColor:NSColor(calibratedWhite:0.88,alpha:1)])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
    private func requestPreview(_ id:Int) {
        guard let index, !previewPending.contains(id), previewPending.count<4 else { return }
        previewPending.insert(id); let generation=previewGeneration, provider=previewProvider
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let value=provider?(index.files[id]) ?? (try? RepoIndexer.readSource(root:index.root,path:index.files[id].path,limit:16_000)).map {String(decoding:$0.prefix(16_000),as:UTF8.self)} ?? "Preview unavailable"
            DispatchQueue.main.async {
                guard let self, self.previewGeneration==generation else {return}
                self.previewPending.remove(id)
                if self.previewCache.count>=32, let first=self.previewCache.keys.sorted().first { self.previewCache.removeValue(forKey:first) }
                self.previewCache[id]=value; self.overlay.needsDisplay=true
            }
        }
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Instance { float4 rect; float4 color; float4 extra; };
    struct Camera { float4 view; float4 pose; };
    struct Out { float4 position [[position]]; float4 color; };
    struct Thumbnail { float4 rect; float4 image; };
    struct ImageOut { float4 position [[position]]; float2 uv; uint slice [[flat]]; float opacity; };
    vertex Out vertexMap(uint v [[vertex_id]], uint i [[instance_id]], const device Instance *items [[buffer(0)]], constant Camera &c [[buffer(1)]]) {
        const float3 vertices[18] = {
            float3(0,0,1),float3(1,0,1),float3(0,1,1),float3(1,0,1),float3(1,1,1),float3(0,1,1),
            float3(0,1,0),float3(0,1,1),float3(1,1,0),float3(1,1,0),float3(0,1,1),float3(1,1,1),
            float3(1,0,0),float3(1,1,0),float3(1,0,1),float3(1,0,1),float3(1,1,0),float3(1,1,1)
        };
        Instance item=items[i]; float3 p=vertices[v]; float tilt=c.view.w;
        float2 world=item.rect.xy+p.xy*item.rect.zw-c.pose.xy;
        float angle=tilt*0.33;
        float2 r=float2(world.x*cos(angle)-world.y*sin(angle),world.x*sin(angle)+world.y*cos(angle));
        float z=p.z*item.extra.x*tilt;
        float2 screen=float2(r.x,r.y*cos(tilt)-z*sin(tilt))*c.view.z+c.view.xy*0.5;
        Out out;
        out.position=float4(screen.x/c.view.x*2-1,1-screen.y/c.view.y*2,clamp(0.5+(-r.y*sin(tilt)-z*cos(tilt))*0.00005,0.001,0.999),1);
        float shade=v<6 ? 1.0 : (v<12 ? 0.50 : 0.72);
        out.color=float4(item.color.rgb*shade,1);
        return out;
    }
    fragment float4 fragmentMap(Out in [[stage_in]]) { return in.color; }
    vertex ImageOut vertexThumbnail(uint v [[vertex_id]], uint i [[instance_id]], const device Thumbnail *items [[buffer(0)]], constant Camera &c [[buffer(1)]]) {
        const float2 corners[6]={float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
        Thumbnail item=items[i]; float2 p=corners[v]; float tilt=c.view.w;
        float2 size=max(float2(1),item.rect.zw*c.view.z-float2(6,28));
        float2 world=item.rect.xy+(float2(3,25)+p*size)/c.view.z-c.pose.xy;
        float angle=tilt*0.33;
        float2 r=float2(world.x*cos(angle)-world.y*sin(angle),world.x*sin(angle)+world.y*cos(angle));
        float z=item.image.w*tilt;
        float2 screen=float2(r.x,r.y*cos(tilt)-z*sin(tilt))*c.view.z+c.view.xy*0.5;
        ImageOut out;
        out.position=float4(screen.x/c.view.x*2-1,1-screen.y/c.view.y*2,clamp(0.5+(-r.y*sin(tilt)-z*cos(tilt))*0.00005,0.001,0.999)-0.000001,1);
        float boxAspect=size.x/size.y, imageAspect=max(0.001,item.image.x);
        float2 crop=float2(min(1.0,boxAspect/imageAspect),min(1.0,imageAspect/boxAspect));
        out.uv=(p-0.5)*crop+0.5; out.slice=uint(item.image.y); out.opacity=item.image.z;
        return out;
    }
    fragment float4 fragmentThumbnail(ImageOut in [[stage_in]], texture2d_array<float> images [[texture(0)]]) {
        constexpr sampler sampleImage(coord::normalized,address::clamp_to_edge,filter::linear);
        return images.sample(sampleImage,in.uv,in.slice)*in.opacity;
    }
    """
}
