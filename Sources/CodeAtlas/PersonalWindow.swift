import AppKit
import AtlasCore

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}
final class PersonalClient {
    private let session:URLSession
    init() { let c=URLSessionConfiguration.ephemeral; c.urlCache=nil; c.httpCookieStorage=nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; session=URLSession(configuration:c,delegate:NoRedirect(),delegateQueue:nil) }
    func request(_ path:String, body:[String:Any]?=nil, token:String="") async throws -> [String:Any] {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:5102"+path)!); request.timeoutInterval=10
        if !token.isEmpty { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        if let body { request.httpMethod="POST"; request.httpBody=try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (bytes,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse, http.statusCode==200 else { throw ProjectionError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var data=Data()
        for try await byte in bytes { try Task.checkCancellation(); data.append(byte); if data.count>1_048_576 { throw ProjectionError.tooLarge } }
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ProjectionError.unavailable}
        return value
    }
    func load(query:String,token:String) async throws -> PersonalProjection {
        let cap=try await request("/api/v2/capabilities",token:token)
        let capabilities=cap["capabilities"] as? [String:Any], pack=capabilities?["context_pack"] as? [String:Any]
        guard cap["contract_version"] as? String=="kernel.v3", pack?["contract"] as? String=="context-pack.v1" else {throw ProjectionError.unavailable}
        // Omitted privacy fields mean the kernel uses only this principal's
        // issued grants. No scope elevation, writes, or remote embeddings.
        let body:[String:Any]=["query":query,"limit":12,"scope":["workspace":"personal","allow_remote_embeddings":false]]
        return try PersonalProjection.parse(try await request("/api/v2/context-packs",body:body,token:token))
    }
}

private final class PersonalCanvas:NSView {
    var projection:PersonalProjection? {didSet{needsDisplay=true}}
    var onSelect:((Int)->Void)?
    var selected:Int? {didSet{needsDisplay=true}}
    override var isFlipped:Bool {true}
    private var rectangles:[CGRect]=[]
    override func draw(_ rect:NSRect) {
        NSColor(calibratedRed:0.035,green:0.055,blue:0.075,alpha:1).setFill(); bounds.fill()
        guard let projection, !projection.areas.isEmpty else {
            ("Your areas, goals, and responsibilities\nappear here after a bounded Personal read." as NSString).draw(in:bounds.insetBy(dx:35,dy:70),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.secondaryLabelColor]); return
        }
        // Equal card area avoids pretending evidence quantity measures importance.
        let columns=max(1,Int(bounds.width/240)), gap:CGFloat=14
        let width=(bounds.width-40-CGFloat(columns-1)*gap)/CGFloat(columns)
        let rows=(projection.areas.count+columns-1)/columns
        let height=min(210,max(90,(bounds.height-40-CGFloat(rows-1)*gap)/CGFloat(rows)))
        rectangles=projection.areas.indices.map { i in CGRect(x:20+CGFloat(i%columns)*(width+gap),y:20+CGFloat(i/columns)*(height+gap),width:width,height:height) }
        for (i,area) in projection.areas.enumerated() {
            let r=rectangles[i]; let color=NSColor(calibratedRed:0.10,green:selected==i ? 0.40 : 0.23,blue:0.31,alpha:1)
            color.setFill(); let path=NSBezierPath(roundedRect:r,xRadius:12,yRadius:12); path.fill()
            let title=area.name+"\n"+area.kind.uppercased()+"\n\(area.claims.count) claims · \(area.sources.count) sources"
            (title as NSString).draw(in:r.insetBy(dx:14,dy:18),withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor.white])
        }
        NSColor.systemTeal.withAlphaComponent(0.5).setStroke()
        if let selected, projection.areas.indices.contains(selected) {
            let id=projection.areas[selected].id
            for link in projection.links where link.from==id || link.to==id {
                guard let a=projection.areas.firstIndex(where:{$0.id==link.from}), let b=projection.areas.firstIndex(where:{$0.id==link.to}) else {continue}
                let line=NSBezierPath(); line.lineWidth=2; line.move(to:CGPoint(x:rectangles[a].midX,y:rectangles[a].midY)); line.line(to:CGPoint(x:rectangles[b].midX,y:rectangles[b].midY)); line.stroke()
            }
        }
    }
    override func mouseDown(with event:NSEvent) { let p=convert(event.locationInWindow,from:nil); if let i=rectangles.firstIndex(where:{$0.contains(p)}) { selected=i; onSelect?(i) } }
}

final class PersonalWindow:NSObject,NSWindowDelegate {
    private var window:NSWindow!
    private let canvas=PersonalCanvas()
    private let detail=NSTextView()
    private let query=NSSearchField()
    private let token=NSSecureTextField()
    private let status=NSTextField(wrappingLabelWithString:"Private native view · no data loaded. Reads use only the kernel-issued scope.")
    private var task:Task<Void,Never>?
    private var projection:PersonalProjection?
    private var sampleMode=false
    override init() {
        super.init()
        window=NSWindow(contentRect:NSRect(x:180,y:120,width:1120,height:720),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Personal · Private context"; window.delegate=self; window.isReleasedWhenClosed=false; window.minSize=NSSize(width:850,height:600)
        window.sharingType = .none
        let outer=NSStackView(); outer.orientation = .vertical; outer.spacing=12; outer.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18)
        window.contentView=outer
        let title=NSTextField(labelWithString:"PERSONAL  /  EVIDENCE & CONNECTIONS"); title.font = .systemFont(ofSize:16,weight:.semibold); outer.addArrangedSubview(title)
        query.placeholderString="Ask about an area, goal, or responsibility"; query.stringValue="Personal life areas, goals, and responsibilities"
        let load=NSButton(title:"Load Personal Context",target:self,action:#selector(loadContext)); load.bezelStyle = .rounded
        let row=NSStackView(views:[query,load,NSButton(title:"Clear & Lock",target:self,action:#selector(clear))]); row.spacing=8; outer.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:outer.widthAnchor,constant:-36).isActive=true
        token.placeholderString="Optional scoped read token · memory only"; token.isHidden=true; outer.addArrangedSubview(token); token.widthAnchor.constraint(equalTo:row.widthAnchor).isActive=true
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; outer.addArrangedSubview(status); status.widthAnchor.constraint(equalTo:row.widthAnchor).isActive=true
        let split=NSSplitView(); split.isVertical=true; split.dividerStyle = .thin; split.addArrangedSubview(canvas)
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; detail.isEditable=false; detail.font = .systemFont(ofSize:13); detail.textContainerInset=NSSize(width:16,height:16); detail.isVerticallyResizable=true; detail.autoresizingMask=[.width]; detail.textContainer?.widthTracksTextView=true; scroll.documentView=detail; split.addArrangedSubview(scroll)
        outer.addArrangedSubview(split); split.widthAnchor.constraint(equalTo:row.widthAnchor).isActive=true; split.heightAnchor.constraint(greaterThanOrEqualToConstant:380).isActive=true; canvas.widthAnchor.constraint(greaterThanOrEqualToConstant:450).isActive=true; scroll.widthAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        if CommandLine.arguments.contains("--demo") {
            let sample=NSButton(title:"Preview with synthetic data",target:self,action:#selector(sample)); outer.addArrangedSubview(sample)
        }
        outer.addArrangedSubview(NSButton(title:"Connection options",target:self,action:#selector(connectionOptions)))
        canvas.onSelect={ [weak self] i in self?.select(i) }
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        if projection == nil && task == nil && !CommandLine.arguments.contains("--demo") {
            if query.stringValue.isEmpty { query.stringValue="Personal life areas, goals, and responsibilities" }
            loadContext()
        }
    }
    func windowWillClose(_ notification:Notification) { clear() }
    @objc private func connectionOptions() { token.isHidden.toggle() }
    @objc private func clear() { task?.cancel(); task=nil; token.stringValue=""; query.stringValue=""; projection=nil; canvas.projection=nil; canvas.selected=nil; detail.string=""; window.sharingType = .none; status.stringValue="Locked · no Personal context retained" }
    @objc private func loadContext() {
        task?.cancel(); projection=nil; canvas.projection=nil; detail.string=""; sampleMode=false; window.sharingType = .none
        let question=String(query.stringValue.prefix(1000)), credential=token.stringValue
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {status.stringValue="Enter a question to keep this read bounded.";return}
        status.stringValue="Loading from Personal on this Mac…"
        task=Task { @MainActor [weak self] in
            do {
                let result=try await PersonalClient().load(query:question,token:credential)
                try Task.checkCancellation(); self?.showProjection(result); self?.task=nil
            } catch {
                guard !Task.isCancelled else {return}
                self?.task=nil
                self?.status.stringValue=(error as? ProjectionError)?.localizedDescription ?? "Personal could not be reached. Nothing was loaded."
            }
        }
    }
    private func showProjection(_ result:PersonalProjection) {
        projection=result; canvas.projection=result; canvas.selected=nil
        status.stringValue=(sampleMode ? "SYNTHETIC DEMO · " : "Local kernel · ")+result.quality+"\nScope: "+result.grants.joined(separator:", ")
        detail.string=result.areas.isEmpty ? "No matching personal-life areas were returned within this credential’s scope. This does not mean your graph is empty.\n\nUse a narrower question or a kernel-issued Personal read token. No access has been expanded." : "Select an area to inspect its claims, connections, and source references.\n\nGenerated: \(result.generated)\nPack: \(result.receipt)\n\nCard size is equal; it does not measure importance."
    }
    private func select(_ id:Int) {
        guard let projection, projection.areas.indices.contains(id) else{return}; let area=projection.areas[id]
        let links=projection.links.filter{$0.from==area.id || $0.to==area.id}.map { link in
            let other=link.from==area.id ? link.to : link.from
            let name=projection.areas.first(where:{$0.id==other})?.name ?? "Unknown"
            return link.from==area.id ? "\(link.kind) → \(name)" : "\(name) → \(link.kind) → this area"
        }
        detail.string="\(area.name)\n\(area.kind) · updated \(area.updated)\n\nCLAIMS\n\(area.claims.isEmpty ? "No claims supplied for this area." : area.claims.joined(separator:"\n\n"))\n\nCONNECTIONS\n\(links.joined(separator:"\n"))\n\nSOURCES\n\(area.sources.isEmpty ? "No linked source references supplied." : area.sources.joined(separator:"\n"))\n\n\(projection.quality)\nPack: \(projection.receipt)"
    }
    @objc private func sample() {
        clear(); sampleMode=true; window.sharingType = .readOnly
        let entities=[["entity_id":"a","display_name":"Learning","entity_type":"area"],["entity_id":"b","display_name":"Finish a course","entity_type":"goal"],["entity_id":"c","display_name":"Weekly practice","entity_type":"responsibility"]]
        let fixture:[String:Any]=["contract":"context-pack.v1","deployment_id":"personal","pack_id":"synthetic-ui-fixture","entities":entities,"claims":[["entity_id":"b","predicate":"status","value":"In progress","status":"supported","evidence_ids":["e1"]]],"evidence":[["evidence_id":"e1","source_uri":"synthetic:weekly-note"]],"relationships":[["source_entity_id":"a","target_entity_id":"b","relationship_type":"supports"],["source_entity_id":"c","target_entity_id":"b","relationship_type":"advances"]],"quality":["grounding":"partial","unknown_freshness_sources":1],"scope":["allowed_privacy":["public"]]]
        if let result=try? PersonalProjection.parse(fixture) {showProjection(result)}
    }
}
