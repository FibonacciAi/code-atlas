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

private final class PersonalDetailStack:NSStackView {
    override var isFlipped:Bool {true}
}

final class PersonalWorkspace:NSView,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    var onReturnToFiles:(()->Void)?
    var supportsSource:((String)->Bool)?
    var onRevealSource:((String)->Void)?
    var hasPrivateContent:Bool {projection != nil}
    private let loader:(String,String) async throws -> PersonalProjection
    private let canvas=PersonalConnectionsView()
    private let query=NSSearchField()
    private let localFilter=NSSearchField()
    private let token=NSSecureTextField()
    private let list=NSTableView()
    private let listSummary=NSTextField(labelWithString:"Your results")
    private let detail=PersonalDetailStack()
    private let detailScroll=NSScrollView()
    private let status=NSTextField(wrappingLabelWithString:"Choose Personal to explore your areas, goals, and connections.")
    private let receipt=NSTextField(wrappingLabelWithString:"")
    private let advanced=NSStackView()
    private let progress=NSProgressIndicator()
    private let searchButton=NSButton(title:"Search",target:nil,action:nil)
    private let split=NSSplitView()
    private var projection:PersonalProjection?
    private var filtered:[PersonalArea]=[]
    private var selectedID:String?
    private var generation=UUID()
    private var task:Task<Void,Never>?
    private var syncingSelection=false
    override var isFlipped:Bool {true}

    init(loader:@escaping (String,String) async throws -> PersonalProjection = {try await PersonalClient().load(query:$0,token:$1)}) {
        self.loader=loader
        super.init(frame:.zero)
        wantsLayer=true; layer?.backgroundColor=NSColor(calibratedRed:0.035,green:0.048,blue:0.067,alpha:1).cgColor
        let files=NSButton(title:"← Files",target:self,action:#selector(returnToFiles))
        let title=NSTextField(labelWithString:"Personal"); title.font = .systemFont(ofSize:19,weight:.semibold)
        query.placeholderString="Ask about an area, goal, or responsibility"; query.target=self; query.action=#selector(loadContext)
        query.sendsSearchStringImmediately=false; query.sendsWholeSearchString=true
        query.setAccessibilityLabel("Question for Personal")
        searchButton.target=self; searchButton.action=#selector(loadContext)
        let lock=NSButton(title:"Lock",target:self,action:#selector(lockAction)); lock.toolTip="Clear Personal results from this view"
        let header=NSStackView(views:[files,title,query,searchButton,lock]); header.spacing=12
        query.widthAnchor.constraint(greaterThanOrEqualToConstant:240).isActive=true
        query.setContentHuggingPriority(.defaultLow,for:.horizontal)
        split.isVertical=true; split.dividerStyle = .thin
        let sidebar=NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing=12
        sidebar.edgeInsets=NSEdgeInsets(top:16,left:14,bottom:12,right:12)
        listSummary.font = .systemFont(ofSize:12,weight:.semibold); listSummary.textColor = .secondaryLabelColor
        localFilter.placeholderString="Find in these results"; localFilter.delegate=self; localFilter.setAccessibilityLabel("Filter Personal results")
        let listScroll=NSScrollView(); listScroll.hasVerticalScroller=true; listScroll.drawsBackground=false
        list.headerView=nil; list.backgroundColor = .clear; list.rowHeight=56; list.intercellSpacing=NSSize(width:0,height:4)
        list.selectionHighlightStyle = .regular; list.usesAlternatingRowBackgroundColors=false
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("area")); list.addTableColumn(column)
        list.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; list.dataSource=self; list.delegate=self; list.setAccessibilityLabel("Personal results")
        listScroll.documentView=list
        sidebar.addArrangedSubview(listSummary); sidebar.addArrangedSubview(localFilter); sidebar.addArrangedSubview(listScroll)
        for view in [localFilter,listScroll] {view.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-26).isActive=true}
        let mapPanel=NSStackView(); mapPanel.orientation = .vertical; mapPanel.spacing=8
        let mapTitle=NSTextField(labelWithString:"Connections"); mapTitle.font = .systemFont(ofSize:13,weight:.semibold)
        let spacer=NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let mapBar=NSStackView(views:[mapTitle,spacer,NSButton(title:"Fit",target:self,action:#selector(fitMap))]); mapBar.edgeInsets=NSEdgeInsets(top:8,left:12,bottom:0,right:12)
        mapPanel.addArrangedSubview(mapBar); mapPanel.addArrangedSubview(canvas)
        mapBar.widthAnchor.constraint(equalTo:mapPanel.widthAnchor).isActive=true; canvas.widthAnchor.constraint(equalTo:mapPanel.widthAnchor).isActive=true
        mapBar.heightAnchor.constraint(equalToConstant:36).isActive=true; canvas.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive=true
        detailScroll.hasVerticalScroller=true; detailScroll.drawsBackground=false
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing=12; detail.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:24,right:18)
        detail.translatesAutoresizingMaskIntoConstraints=false; detailScroll.documentView=detail
        NSLayoutConstraint.activate([detail.leadingAnchor.constraint(equalTo:detailScroll.contentView.leadingAnchor),detail.topAnchor.constraint(equalTo:detailScroll.contentView.topAnchor),detail.widthAnchor.constraint(equalTo:detailScroll.contentView.widthAnchor)])
        split.addArrangedSubview(sidebar); split.addArrangedSubview(mapPanel); split.addArrangedSubview(detailScroll)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant:300).isActive=true
        mapPanel.widthAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant:285).isActive=true
        detailScroll.widthAnchor.constraint(lessThanOrEqualToConstant:440).isActive=true
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped=false
        status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor
        let advancedButton=NSButton(title:"Read details",target:self,action:#selector(toggleDetails))
        let footer=NSStackView(views:[progress,status,advancedButton]); footer.spacing=10
        status.setContentHuggingPriority(.defaultLow,for:.horizontal)
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing=8; advanced.isHidden=true
        receipt.maximumNumberOfLines=6; receipt.font = .systemFont(ofSize:11); receipt.textColor = .secondaryLabelColor; receipt.isSelectable=true
        token.placeholderString="Optional Personal read token · cleared when you leave Personal"
        token.setAccessibilityLabel("Optional Personal read token")
        advanced.addArrangedSubview(receipt); advanced.addArrangedSubview(token)
        for view in [receipt,token] {view.widthAnchor.constraint(equalTo:advanced.widthAnchor).isActive=true}
        let outer=NSStackView(views:[header,split,footer,advanced]); outer.orientation = .vertical; outer.alignment = .leading; outer.spacing=12
        outer.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:14,right:16); outer.translatesAutoresizingMaskIntoConstraints=false; addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo:leadingAnchor),outer.trailingAnchor.constraint(equalTo:trailingAnchor),outer.topAnchor.constraint(equalTo:topAnchor),outer.bottomAnchor.constraint(equalTo:bottomAnchor)])
        for view in [header,split,footer,advanced] {view.widthAnchor.constraint(equalTo:outer.widthAnchor,constant:-32).isActive=true}
        split.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        canvas.onSelect={ [weak self] id in self?.select(id,focus:false) }
        showEmptyDetail("Select an area",message:"Choose a result or a connection to see its evidence here.")
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {task?.cancel()}
    func activate() {
        guard projection == nil,task == nil else {return}
        if query.stringValue.isEmpty {query.stringValue="Personal life areas, goals, and responsibilities"}
        loadContext()
    }
    func focusSearch() {window?.makeFirstResponder(query)}
    func lock() {
        generation=UUID(); task?.cancel(); task=nil; progress.stopAnimation(nil); searchButton.isEnabled=true
        if !isHidden,let editor=window?.firstResponder as? NSTextView,editor.isFieldEditor {
            window?.makeFirstResponder(nil)
            editor.undoManager?.removeAllActions();editor.string=""
        }
        projection=nil; filtered=[]; selectedID=nil; query.stringValue=""; token.stringValue=""; localFilter.stringValue=""
        canvas.projection=nil; canvas.selectedID=nil; list.reloadData(); listSummary.stringValue="Your results"
        receipt.stringValue=""; advanced.isHidden=true
        showEmptyDetail("Personal is locked",message:"Search again when you’re ready. Nothing from the last read remains in this view.")
        status.stringValue="Locked · Personal results cleared"
    }
    @objc private func lockAction() {lock()}
    @objc private func returnToFiles() {lock();onReturnToFiles?()}
    @objc private func fitMap() {canvas.fit()}
    @objc private func toggleDetails() {advanced.isHidden.toggle()}
    @objc private func loadContext() {
        let question=String(query.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).prefix(1000))
        guard !question.isEmpty else {status.stringValue="Enter a question about what you want to explore.";focusSearch();return}
        task?.cancel(); generation=UUID(); let request=generation,credential=token.stringValue,load=loader
        projection=nil; filtered=[]; selectedID=nil; canvas.projection=nil; canvas.selectedID=nil; list.reloadData(); receipt.stringValue=""
        localFilter.stringValue=""; listSummary.stringValue="Searching…"
        showEmptyDetail("Finding your context",message:"Results and their evidence will appear together here.")
        status.stringValue="Reading Personal on this Mac…"; progress.startAnimation(nil)
        // Keep Search enabled so a new question can supersede this read.
        task=Task { @MainActor [weak self] in
            do {
                let result=try await load(question,credential); try Task.checkCancellation()
                guard let self,self.generation==request else {return}
                self.task=nil;self.progress.stopAnimation(nil);self.showProjection(result)
            } catch {
                guard let self,self.generation==request,!Task.isCancelled else {return}
                self.task=nil;self.progress.stopAnimation(nil);self.listSummary.stringValue="No results loaded"
                self.status.stringValue=self.friendlyError(error)
                self.showEmptyDetail("Personal couldn’t load",message:"Your files remain available. Try again, or check Read details if a read token is needed.")
                self.receipt.stringValue=(error as? ProjectionError)?.localizedDescription ?? "The local Personal read did not complete."
            }
        }
    }
    private func friendlyError(_ error:Error)->String {
        guard let error=error as? ProjectionError else {return "Personal couldn’t be reached. Try again in a moment."}
        switch error {
        case .rejected(let code) where code==401 || code==403:return "Personal needs read access. Open Read details to provide a scoped token."
        case .tooLarge:return "That result was too large. Try a more specific question."
        case .wrongDeployment:return "Personal returned an unexpected reply. No results were shown."
        default:return "Personal isn’t available right now. Your files still work."
        }
    }
    private func showProjection(_ result:PersonalProjection) {
        projection=result;canvas.projection=result;filtered=result.areas;list.reloadData()
        listSummary.stringValue="Results for your question"
        receipt.stringValue="Read at: \(result.generated)\n\(result.quality)\nRead scope: \(result.grants.joined(separator:", "))\nReceipt: \(result.receipt)"
        status.stringValue=result.readSummary+" · Read on this Mac"
        if let first=result.areas.first {select(first.id,focus:false);canvas.fit()}
        else {
            showEmptyDetail("No matching areas returned",message:"This question returned no matching areas within your access. It does not mean your Personal context is empty. Try a narrower question.")
            status.stringValue="No matches for this question · Try another area, goal, or responsibility"
        }
    }
    func controlTextDidChange(_ notification:Notification) {
        let text=localFilter.stringValue
        filtered=projection?.areas.filter {text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.kind.localizedCaseInsensitiveContains(text)} ?? []
        syncingSelection=true;list.reloadData();syncingSelection=false;syncListSelection()
        listSummary.stringValue=filtered.isEmpty && projection != nil ? "No results match this filter" : "Results for your question"
    }
    func numberOfRows(in tableView:NSTableView)->Int {filtered.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard filtered.indices.contains(row) else {return nil}
        let area=filtered[row],cell=NSTextField(wrappingLabelWithString:area.name+"\n"+area.kind.capitalized)
        cell.font = .systemFont(ofSize:13,weight:.medium);cell.maximumNumberOfLines=2;cell.lineBreakMode = .byTruncatingTail
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !syncingSelection,filtered.indices.contains(list.selectedRow) else {return}
        select(filtered[list.selectedRow].id,focus:true)
    }
    private func syncListSelection() {
        syncingSelection=true;defer {syncingSelection=false}
        if let row=filtered.firstIndex(where:{$0.id==selectedID}) {list.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);list.scrollRowToVisible(row)}
        else {list.deselectAll(nil)}
    }
    private func select(_ id:String,focus:Bool) {
        guard let projection,let area=projection.areas.first(where:{$0.id==id}) else {return}
        selectedID=id;canvas.selectedID=id;syncListSelection();if focus {canvas.focus(id:id)}
        clearDetail();addLabel(area.name,size:20,bold:true);addLabel(area.kind.capitalized+" · Updated "+area.updated,size:11)
        addLabel("Evidence",size:13,bold:true)
        if area.claims.isEmpty {addLabel("No claims were supplied for this result.")}
        else {for claim in area.claims {addLabel(claim)}}
        addLabel("Connections",size:13,bold:true)
        let links=projection.links.filter {$0.from==id || $0.to==id}
        if links.isEmpty {addLabel("No connections were returned for this result.")}
        for link in links {
            let outgoing=link.from==id,other=outgoing ? link.to : link.from
            let name=projection.areas.first(where:{$0.id==other})?.name ?? "Connected area"
            let relation=link.kind.replacingOccurrences(of:"_",with:" ")
            addLabel(outgoing ? relation+" →" : "← "+relation,size:11)
            let button=NSButton(title:name,target:self,action:#selector(selectConnection));button.identifier=NSUserInterfaceItemIdentifier(other)
            button.bezelStyle = .rounded;detail.addArrangedSubview(button)
            button.widthAnchor.constraint(lessThanOrEqualTo:detail.widthAnchor,constant:-36).isActive=true
        }
        addLabel("Sources",size:13,bold:true)
        if area.sources.isEmpty {addLabel("No source references were supplied.")}
        for source in area.sources {
            let reference=URL(string:source)
            let name=reference?.lastPathComponent.isEmpty == false ? reference!.lastPathComponent : source
            addLabel(String(name.prefix(180)),size:12,bold:true).toolTip=source
            if supportsSource?(source)==true {
                let button=NSButton(title:"Open in Files",target:self,action:#selector(revealSource));button.identifier=NSUserInterfaceItemIdentifier(source);detail.addArrangedSubview(button)
            }
        }
        scrollDetailToTop()
    }
    @objc private func selectConnection(_ sender:NSButton) {if let id=sender.identifier?.rawValue {select(id,focus:true)}}
    @objc private func revealSource(_ sender:NSButton) {
        guard let ref=sender.identifier?.rawValue,supportsSource?(ref)==true else {return}
        onRevealSource?(ref)
    }
    private func clearDetail() {detail.arrangedSubviews.forEach {detail.removeArrangedSubview($0);$0.removeFromSuperview()}}
    @discardableResult private func addLabel(_ text:String,size:CGFloat=13,bold:Bool=false)->NSTextField {
        let label=NSTextField(wrappingLabelWithString:text);label.font = .systemFont(ofSize:size,weight:bold ? .semibold : .regular);label.isSelectable=true
        if size<=11 {label.textColor = .secondaryLabelColor}
        detail.addArrangedSubview(label);label.widthAnchor.constraint(equalTo:detail.widthAnchor,constant:-36).isActive=true
        return label
    }
    private func scrollDetailToTop() {
        detail.layoutSubtreeIfNeeded();detailScroll.contentView.scroll(to:.zero)
        detailScroll.reflectScrolledClipView(detailScroll.contentView)
    }
    private func showEmptyDetail(_ title:String,message:String) {clearDetail();addLabel(title,size:18,bold:true);addLabel(message);scrollDetailToTop()}
}
