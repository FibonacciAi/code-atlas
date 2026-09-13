import AppKit
import AtlasCore

final class Cancellation: @unchecked Sendable {
    private let lock=NSLock(); private var value=false
    func cancel() { lock.lock(); value=true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var statusItem:NSStatusItem?
    let map=MetalMap()
    let rootPicker=NSPopUpButton()
    let search=NSSearchField()
    let table=NSTableView()
    let titleLabel=NSTextField(labelWithString:"Whitespace Master")
    let metrics=NSTextField(labelWithString:"Choose a project to begin")
    let status=NSTextField(labelWithString:"Local source • read only")
    let zoomLabel=NSTextField(labelWithString:"100%")
    let kernelStatus=NSTextField(wrappingLabelWithString:"Personal service · checking…")
    let source=NSTextView()
    let fileTitle=NSTextField(wrappingLabelWithString:"Explore the map")
    let fileMeta=NSTextField(wrappingLabelWithString:"Select a file to read its source. Double click to fly into it.")
    let sourceStatus=NSTextField(wrappingLabelWithString:"Source is loaded only when selected.")
    let outlinePicker=NSPopUpButton()
    let progress=NSProgressIndicator()
    let cancelButton=NSButton(title:"Cancel",target:nil,action:nil)
    let backButton=NSButton(title:"Back",target:nil,action:nil)
    let folderPicker=NSPopUpButton()
    let colors=NSPopUpButton()
    let sizing=NSPopUpButton()
    let kindFilter=NSPopUpButton()
    let changesOnly=NSButton(checkboxWithTitle:"Changed files only",target:nil,action:nil)
    let gitSummary=NSTextField(wrappingLabelWithString:"Git changes · checking…")
    let linksPicker=NSPopUpButton()
    let symbolField=NSSearchField()
    var linkIDs:[Int]=[]
    var gitChanges: GitChanges?
    var usageHits:[Int:Int]?
    var usageTask: Cancellation?
    var folderPaths:[String]=[]
    var personalWindow: PersonalWindow?
    var inspectorPanel:NSView!
    var mainSplit:NSSplitView!
    var roots: [URL]=[]
    var index: RepositoryIndex?
    var matching: [Int]=[]
    var outlineLines: [Int]=[]
    var cancel: Cancellation?
    var generation=UUID()
    var selectedID: Int?
    var demo=CommandLine.arguments.contains("--demo")
    private var selectionFromMap=false
    // Rebuildable metadata/layout only: no file text, previews, or Personal data.
    private var recentIndexes:[URL:(RepositoryIndex,MapLayout)]=[:]
    private var recentIndexOrder:[URL]=[]
    private var requestedRoot:URL?
    private var showingCachedIndex=false
    private let verificationRoots:[URL]?
    private let preferences:UserDefaults
    init(verificationRoots:[URL]?=nil) {
        self.verificationRoots=verificationRoots
        self.preferences=verificationRoots == nil ? .standard : UserDefaults(suiteName:"local.codeatlas.verification.projects")!
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance=NSAppearance(named:.darkAqua)
        makeMenu(); buildWindow()
        if let verificationRoots {
            demo=false; roots=verificationRoots; updateRoots()
            window.title="Code Atlas · Folder Verification"
            kernelStatus.stringValue="Folder verification · generated local files only\nPersonal and kernel access disabled"
            if let root=roots.first {load(root)}
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            return
        }
        makeStatusItem()
        if let icon=NSImage(named:"AppIcon") {NSApp.applicationIconImage=icon}
        let docs=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        roots=["whitespace_master","whitespace-personal","whitespace-context-kernel"].map { docs.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath:$0.path) }
        let operatorCheckout=docs.appendingPathComponent("whitespace_master/tmp/drop-chat-voice-20260908")
        if FileManager.default.fileExists(atPath:operatorCheckout.path) { roots.append(operatorCheckout) }
        let removed=Set(self.preferences.stringArray(forKey:"removedProjectRoots") ?? [])
        roots.removeAll {removed.contains($0.path)}
        for path in self.preferences.stringArray(forKey:"projectRoots") ?? [] {
            let url=URL(fileURLWithPath:path)
            if !roots.contains(url), !removed.contains(path), ProjectIdentity.rejection(url)==nil, FileManager.default.fileExists(atPath:path) { roots.append(url) }
        }
        updateRoots()
        if demo { loadDemo() }
        else if let saved=self.preferences.string(forKey:"lastProject"), let n=roots.firstIndex(where:{$0.path == saved}) { rootPicker.selectItem(at:n); load(roots[n]) }
        else if let root=roots.first { load(root) }
        probeKernel()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func makeMenu() {
        let menu=NSMenu(); let app=NSMenuItem(); menu.addItem(app); let appMenu=NSMenu(); app.submenu=appMenu
        let about=NSMenuItem(title:"About Code Atlas",action:#selector(showAbout),keyEquivalent:""); about.target=self; appMenu.addItem(about)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Code Atlas",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file=NSMenuItem(); file.submenu=NSMenu(title:"File"); menu.addItem(file)
        let open=NSMenuItem(title:"Open Folder…",action:#selector(chooseProject),keyEquivalent:"o"); open.target=self; file.submenu?.addItem(open)
        let edit=NSMenuItem(); edit.submenu=NSMenu(title:"Edit"); menu.addItem(edit)
        edit.submenu?.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.submenu?.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.submenu?.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let find=NSMenuItem(title:"Find File",action:#selector(focusSearch),keyEquivalent:"f"); find.target=self; edit.submenu?.addItem(find)
        NSApp.mainMenu=menu
    }
    func label(_ text: String, size: CGFloat=12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let v=NSTextField(labelWithString:text); v.font = .systemFont(ofSize:size,weight:.medium); v.textColor=color; return v
    }
    func button(_ text: String, _ action: Selector) -> NSButton {
        let v=NSButton(title:text,target:self,action:action); v.bezelStyle = .rounded; return v
    }
    func pin(_ child: NSView, to parent: NSView, inset: CGFloat=0) {
        child.translatesAutoresizingMaskIntoConstraints=false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),child.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),child.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),child.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
    }
    func buildWindow() {
        window=NSWindow(contentRect:NSRect(x:100,y:80,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.title="Code Atlas"; window.minSize=NSSize(width:1180,height:780); window.titlebarAppearsTransparent=true
        window.backgroundColor=NSColor(calibratedRed:0.035,green:0.048,blue:0.067,alpha:1)
        let whole=NSStackView(); whole.orientation = .vertical; whole.spacing=0
        pin(whole,to:window.contentView!)
        let toolbar=NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing=8; toolbar.edgeInsets=NSEdgeInsets(top:14,left:20,bottom:14,right:20)
        let brand=label("◈  CODE ATLAS",size:14,color:.labelColor); brand.font = .systemFont(ofSize:14,weight:.bold)
        toolbar.addArrangedSubview(brand)
        let spacer=NSView(); toolbar.addArrangedSubview(spacer); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        rootPicker.target=self; rootPicker.action=#selector(rootChanged); rootPicker.widthAnchor.constraint(equalToConstant:230).isActive=true
        toolbar.addArrangedSubview(rootPicker); toolbar.addArrangedSubview(button("Open Folder…",#selector(chooseProject)))
        toolbar.addArrangedSubview(button("Refresh",#selector(refresh)))
        let mode=NSSegmentedControl(labels:["Map","City"],trackingMode:.selectOne,target:self,action:#selector(modeChanged)); mode.selectedSegment=0; toolbar.addArrangedSubview(mode)
        toolbar.addArrangedSubview(button("Fit",#selector(fit))); zoomLabel.widthAnchor.constraint(equalToConstant:48).isActive=true; zoomLabel.alignment = .right; toolbar.addArrangedSubview(zoomLabel)
        toolbar.addArrangedSubview(button("Inspector",#selector(toggleInspector)))
        whole.addArrangedSubview(toolbar); toolbar.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        let split=NSSplitView(); split.isVertical=true; split.dividerStyle = .thin
        mainSplit=split
        whole.addArrangedSubview(split); split.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        let sidebar=NSView(); let inspector=NSView()
        inspectorPanel=inspector
        let mapContainer=NSView(); pin(map,to:mapContainer)
        split.addArrangedSubview(sidebar); split.addArrangedSubview(mapContainer); split.addArrangedSubview(inspector)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:210).isActive=true; sidebar.widthAnchor.constraint(lessThanOrEqualToConstant:285).isActive=true
        inspector.widthAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        inspector.widthAnchor.constraint(lessThanOrEqualToConstant:460).isActive=true
        map.widthAnchor.constraint(greaterThanOrEqualToConstant:380).isActive=true
        let left=NSStackView(); left.orientation = .vertical; left.alignment = .leading; left.spacing=12
        pin(left,to:sidebar,inset:16)
        left.addArrangedSubview(label("WORKSPACE",size:10)); titleLabel.font = .systemFont(ofSize:19,weight:.semibold); left.addArrangedSubview(titleLabel)
        titleLabel.lineBreakMode = .byTruncatingTail; titleLabel.maximumNumberOfLines=2; titleLabel.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        metrics.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); left.addArrangedSubview(metrics)
        let projectActions=NSStackView(views:[button("Remove from list",#selector(removeProject)),button("Show Folder",#selector(revealProject))]); projectActions.spacing=6; left.addArrangedSubview(projectActions)
        folderPicker.target=self; folderPicker.action=#selector(jumpFolder); left.addArrangedSubview(folderPicker); folderPicker.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        backButton.target=self; backButton.action=#selector(goBack); backButton.isEnabled=false
        colors.addItems(withTitles:["Color by folder","Color by language","Color by Git changes"]); colors.target=self; colors.action=#selector(colorChanged)
        left.addArrangedSubview(NSStackView(views:[backButton,colors]))
        changesOnly.target=self; changesOnly.action=#selector(changeFilter); sizing.addItems(withTitles:["Size · balanced","Size · lines of code","Size · bytes","Size · equal tiles"]); sizing.target=self; sizing.action=#selector(resizeMap)
        kindFilter.addItems(withTitles:["All content","Code & HTML","Photos","Video & audio","Documents"]); kindFilter.target=self; kindFilter.action=#selector(changeFilter)
        left.addArrangedSubview(sizing); left.addArrangedSubview(kindFilter)
        sizing.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true; kindFilter.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        left.addArrangedSubview(changesOnly)
        gitSummary.font = .systemFont(ofSize:10); gitSummary.textColor = .secondaryLabelColor; left.addArrangedSubview(gitSummary); gitSummary.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        search.placeholderString="Find a file…  ⌘F"; search.delegate=self; search.sendsSearchStringImmediately=true
        left.addArrangedSubview(search); search.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.drawsBackground=false
        let col=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("file")); col.title="Files"; col.width=220; table.addTableColumn(col)
        table.headerView=nil; table.backgroundColor = .clear; table.rowHeight=46; table.style = .inset; table.delegate=self; table.dataSource=self
        table.target=self; table.doubleAction=#selector(previewSelected)
        scroll.documentView=table; left.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
        left.addArrangedSubview(label("PERSONAL · ON THIS MAC",size:10))
        kernelStatus.font = .systemFont(ofSize:11); kernelStatus.textColor = .secondaryLabelColor; left.addArrangedSubview(kernelStatus)
        kernelStatus.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        left.addArrangedSubview(label("Local files · no graph files",size:11))
        left.addArrangedSubview(button("Open Personal View…",#selector(openPersonal)))
        let right=NSStackView(); right.orientation = .vertical; right.alignment = .leading; right.spacing=12
        pin(right,to:inspector,inset:16)
        right.addArrangedSubview(label("FILE INSPECTOR",size:10)); fileTitle.font = .systemFont(ofSize:17,weight:.semibold); right.addArrangedSubview(fileTitle)
        fileTitle.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        fileMeta.font = .monospacedSystemFont(ofSize:11,weight:.regular); fileMeta.textColor = .secondaryLabelColor; right.addArrangedSubview(fileMeta)
        fileMeta.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        outlinePicker.addItem(withTitle:"Outline · select a file"); outlinePicker.isEnabled=false; outlinePicker.target=self; outlinePicker.action=#selector(jumpOutline)
        right.addArrangedSubview(outlinePicker); outlinePicker.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        right.addArrangedSubview(NSStackView(views:[button("Preview",#selector(previewSelected)),button("Open",#selector(openSelected))]))
        right.addArrangedSubview(NSStackView(views:[button("Focus File",#selector(focusSelected)),button("Focus Folder",#selector(focusFolder))]))
        linksPicker.addItem(withTitle:"Imports · select a file"); linksPicker.isEnabled=false; linksPicker.target=self; linksPicker.action=#selector(jumpLink)
        right.addArrangedSubview(linksPicker); linksPicker.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        symbolField.placeholderString="Identifier to find across code"; symbolField.target=self; symbolField.action=#selector(findUsages)
        right.addArrangedSubview(symbolField); symbolField.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        right.addArrangedSubview(NSStackView(views:[button("Find Occurrences",#selector(findUsages)),button("Clear",#selector(clearUsages))]))
        let sourceScroll=NSScrollView(); sourceScroll.hasVerticalScroller=true; sourceScroll.hasHorizontalScroller=true; sourceScroll.borderType = .noBorder
        source.isEditable=false; source.isSelectable=true; source.isRichText=false; source.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        source.backgroundColor=NSColor(calibratedWhite:0.055,alpha:1); source.textColor=NSColor(calibratedRed:0.78,green:0.86,blue:0.86,alpha:1)
        source.textContainerInset=NSSize(width:12,height:14); source.autoresizingMask=[.width]; source.isVerticallyResizable=true; source.isHorizontallyResizable=false
        source.textContainer?.widthTracksTextView=true; sourceScroll.documentView=source
        right.addArrangedSubview(sourceScroll); sourceScroll.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true; sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
        sourceStatus.font = .systemFont(ofSize:10); sourceStatus.textColor = .secondaryLabelColor; right.addArrangedSubview(sourceStatus); sourceStatus.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
        let bottom=NSStackView(); bottom.orientation = .horizontal; bottom.spacing=12; bottom.edgeInsets=NSEdgeInsets(top:10,left:20,bottom:10,right:20)
        status.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        bottom.addArrangedSubview(status); progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped=false; bottom.addArrangedSubview(progress)
        cancelButton.target=self; cancelButton.action=#selector(cancelScan); cancelButton.isHidden=true; bottom.addArrangedSubview(cancelButton)
        let gap=NSView(); bottom.addArrangedSubview(gap)
        bottom.addArrangedSubview(label("Drag to pan · Scroll / pinch to zoom · Double click to focus",size:10))
        whole.addArrangedSubview(bottom); bottom.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        split.setPosition(260,ofDividerAt:0); split.setPosition(1050,ofDividerAt:1)
        inspector.isHidden=true
        map.onSelect={ [weak self] id in self?.select(id,fromMap:true) }
        map.onPreviewSelection={ [weak self] id in self?.select(id,fromMap:true,revealInspector:false) }
        map.onCamera={ [weak self] value in self?.zoomLabel.stringValue=value }
        map.onHistory={ [weak self] available in self?.backButton.isEnabled=available }
        if let error=map.rendererError { status.stringValue="Metal renderer failed: \(error)" }
    }
    func updateRoots() { rootPicker.removeAllItems(); roots.forEach { rootPicker.addItem(withTitle:ProjectIdentity.title($0)) } }
    @objc func chooseProject() {
        guard verificationRoots == nil else {status.stringValue="Folder verification uses only its generated fixture folders.";return}
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.allowsMultipleSelection=false; panel.prompt="Open Atlas"
        panel.message="Choose a folder of projects, photos, videos, or documents. Your files stay in place."
        panel.beginSheetModal(for:window) { [weak self] result in
            guard let self, result == .OK else { return }
            if let url=panel.urls.first { self.load(url) }
        }
    }
    @objc func rootChanged() { let n=rootPicker.indexOfSelectedItem; if roots.indices.contains(n) { load(roots[n]); probeKernel() } }
    @objc func refresh() {
        if demo {loadDemo()}
        else {let n=rootPicker.indexOfSelectedItem; if roots.indices.contains(n) {load(roots[n])}}
        probeKernel()
    }
    @objc func modeChanged(_ control: NSSegmentedControl) { map.setCity(control.selectedSegment == 1) }
    @objc func fit() { map.fit() }
    @objc func focusSearch() { window.makeFirstResponder(search) }
    @objc func focusSelected() { if let selectedID { map.focus(selectedID) } }
    @objc func goBack() { map.goBack() }
    @objc func jumpFolder() { if folderPaths.indices.contains(folderPicker.indexOfSelectedItem) { map.focusFolder(folderPaths[folderPicker.indexOfSelectedItem]) } }
    @objc func focusFolder() { if let index, let selectedID { map.focusFolder((index.files[selectedID].path as NSString).deletingLastPathComponent) } }
    @objc func toggleInspector() { inspectorPanel.isHidden.toggle(); mainSplit.adjustSubviews(); map.fit() }
    @objc func colorChanged() { map.colorMode=colors.indexOfSelectedItem }
    @objc func previewSelected() {if let selectedID {map.openFile(selectedID)}}
    @objc func openSelected() {
        guard let index, let selectedID, let url=try? RepoIndexer.validatedURL(root:index.root,path:index.files[selectedID].path) else {return}
        NSWorkspace.shared.open(url)
    }
    @objc func resizeMap() {
        guard let index else {return}
        map.load(index,layout:Treemap.layout(index.files,sizing:AtlasSizing(rawValue:sizing.indexOfSelectedItem) ?? .balanced)); filter()
    }
    @objc func changeFilter() { filter() }
    @objc func openPersonal() { guard verificationRoots == nil else {return}; if personalWindow==nil { personalWindow=PersonalWindow() }; personalWindow?.show() }
    @objc func revealProject() { if let index { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:index.root.path) } }
    @objc func removeProject() {
        let n=rootPicker.indexOfSelectedItem; guard roots.indices.contains(n) else { return }
        let removed=roots.remove(at:n)
        recentIndexes.removeValue(forKey:removed.standardizedFileURL); recentIndexOrder.removeAll {$0 == removed.standardizedFileURL}
        var hidden=Set(self.preferences.stringArray(forKey:"removedProjectRoots") ?? []); hidden.insert(removed.path)
        self.preferences.set(Array(hidden),forKey:"removedProjectRoots"); self.preferences.set(roots.map(\.path),forKey:"projectRoots")
        cancel?.cancel(); generation=UUID(); updateRoots()
        if let root=roots.first { load(root) }
        else { finishScan(); requestedRoot=nil; index=nil; matching=[]; table.reloadData(); titleLabel.stringValue="Choose a source project"; metrics.stringValue="No projects in this list"; map.clear(); source.string=""; status.stringValue="Removed from list. No files were deleted."; self.preferences.removeObject(forKey:"lastProject") }
    }
    @objc func cancelScan() {
        cancel?.cancel(); generation=UUID(); finishScan()
        status.stringValue=showingCachedIndex ? "Refresh cancelled · cached map remains available" : "Indexing cancelled · choose another folder or Refresh to retry"
    }
    private func remember(_ value:RepositoryIndex,layout:MapLayout,for root:URL) {
        let key=root.standardizedFileURL
        recentIndexes[key]=(value,layout); recentIndexOrder.removeAll {$0==key}; recentIndexOrder.append(key)
        while recentIndexOrder.count>3 {recentIndexes.removeValue(forKey:recentIndexOrder.removeFirst())}
    }
    private func showLoadingProject(_ root:URL) {
        usageTask?.cancel(); usageHits=nil; index=nil; selectedID=nil; matching=[]; table.reloadData()
        map.clear(); map.previewProvider=nil; map.selectedSource=""; map.query=""; search.stringValue=""
        titleLabel.stringValue=ProjectIdentity.title(root); metrics.stringValue="Reading folder…"
        fileTitle.stringValue="Opening folder"; fileMeta.stringValue="The map will appear when indexing finishes."; source.string=""
        sourceStatus.stringValue="You can choose another folder or cancel at any time."
        folderPaths=[]; folderPicker.removeAllItems(); folderPicker.addItem(withTitle:"Whole project")
        outlinePicker.removeAllItems(); outlinePicker.addItem(withTitle:"Outline · select a file"); outlinePicker.isEnabled=false
        linkIDs=[]; linksPicker.removeAllItems(); linksPicker.isEnabled=false
        gitChanges=nil; gitSummary.stringValue="Git changes · waiting for folder"
    }
    func finishScan() { progress.stopAnimation(nil); cancelButton.isHidden=true }
    func load(_ root: URL) {
        if let verificationRoots,!verificationRoots.contains(where:{$0.standardizedFileURL==root.standardizedFileURL}) {return}
        if let reason=ProjectIdentity.rejection(root) { status.stringValue=reason; return }
        demo=false
        cancel?.cancel(); usageTask?.cancel()
        let token=Cancellation(); cancel=token; let request=UUID(); generation=request
        let key=root.standardizedFileURL; requestedRoot=key
        if let n=roots.firstIndex(of:root) {rootPicker.selectItem(at:n)}
        showingCachedIndex=false
        if let cached=recentIndexes[key] {
            // display() closes any open file before switching the visible map.
            display(cached.0,layout:cached.1)
            remember(cached.0,layout:cached.1,for:root)
            showingCachedIndex=true
            self.preferences.set(root.path,forKey:"lastProject")
        } else {showLoadingProject(root)}
        let initialSnapshot=index
        let preserveCurrentView=showingCachedIndex
        progress.startAnimation(nil); cancelButton.isHidden=false
        status.stringValue=showingCachedIndex ? "Cached map · refreshing \(ProjectIdentity.title(root))…" : "Indexing \(ProjectIdentity.title(root))… · You can switch folders while this runs"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {
                let index=try RepoIndexer.scan(root,includeMedia:true,cancelled:{token.cancelled})
                guard !token.cancelled else {throw IndexError.cancelled}
                let layout=Treemap.layout(index.files,sizing:.balanced)
                guard !token.cancelled else {throw IndexError.cancelled}
                return (index,layout)
            }
            DispatchQueue.main.async {
                guard let self,self.generation==request,self.requestedRoot==key,!token.cancelled else {return}
                self.finishScan()
                switch result {
                case .success(let (index,layout)):
                    guard !index.files.isEmpty else {
                        self.status.stringValue=self.showingCachedIndex ? "No supported files found on refresh · cached map retained" : "No supported files found. Choose a folder containing code, photos, media, or documents."
                        self.metrics.stringValue=self.showingCachedIndex ? self.metrics.stringValue : "No supported files"
                        return
                    }
                    if !self.roots.contains(root) {self.roots.append(root)}
                    self.updateRoots(); if let n=self.roots.firstIndex(of:root) {self.rootPicker.selectItem(at:n)}
                    var hidden=Set(self.preferences.stringArray(forKey:"removedProjectRoots") ?? []); hidden.remove(root.path); self.preferences.set(Array(hidden),forKey:"removedProjectRoots")
                    self.remember(index,layout:layout,for:root)
                    if preserveCurrentView {
                        // Keep the current camera, selection, and reader untouched.
                        // The latest snapshot is applied only by a subsequent explicit
                        // Refresh or folder switch, which takes the cached path above.
                        let sameMetadata=initialSnapshot.map { previous in
                            previous.files.count==index.files.count && zip(previous.files,index.files).allSatisfy { a,b in
                                a.path==b.path && a.lines==b.lines && a.bytes==b.bytes
                            }
                        } ?? false
                        self.status.stringValue=sameMetadata ? "Folder scan finished · file sizes unchanged · current view preserved" : "Updated scan ready · Refresh to apply"
                    } else {
                        self.showingCachedIndex=false; self.display(index,layout:layout)
                    }
                    self.preferences.set(self.roots.map(\.path),forKey:"projectRoots")
                    self.preferences.set(root.path,forKey:"lastProject")
                case .failure(let error):
                    self.status.stringValue=self.showingCachedIndex ? "Refresh failed · cached map retained · \(error.localizedDescription)" : error.localizedDescription
                    if !self.showingCachedIndex {self.metrics.stringValue="Folder could not be indexed"}
                }
            }
        }
    }
    func display(_ value: RepositoryIndex, layout: MapLayout) {
        usageTask?.cancel(); usageHits=nil; index=value; selectedID=nil; search.stringValue=""; map.query=""; titleLabel.stringValue=ProjectIdentity.title(value.root)
        metrics.stringValue="\(value.files.count.formatted()) files · \(ByteCountFormatter.string(fromByteCount:Int64(value.files.reduce(0){$0+$1.bytes}),countStyle:.file))"
        fileTitle.stringValue="Explore the map"; fileMeta.stringValue="Balanced file sizes · choose a size metric\nZoom into a file to open it"; source.string=""; map.selectedSource=""
        outlinePicker.removeAllItems(); outlinePicker.addItem(withTitle:"Outline · select a file"); outlinePicker.isEnabled=false
        sourceStatus.stringValue="Read only · local source · outline uses lexical matching"
        map.load(value,layout:layout); filter()
        folderPaths=[""]+layout.folders.map(\.path).sorted(); folderPicker.removeAllItems(); folderPicker.addItem(withTitle:"Whole project"); folderPaths.dropFirst().forEach { folderPicker.addItem(withTitle:$0) }
        map.previewProvider=demo ? { file in Self.demoSource(file) } : nil
        gitChanges=nil; map.gitStatuses=[:]; gitSummary.stringValue="Git changes · checking…"
        let request=generation
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let changes=try? GitChanges.read(value.root)
            DispatchQueue.main.async {
                guard let self, self.generation==request else { return }
                self.gitChanges=changes; self.map.gitStatuses=changes?.statuses ?? [:]
                self.gitSummary.stringValue=changes.map { "\($0.statuses.count) changed source paths · \($0.deleted) deleted\nGreen added · amber edited · pink renamed" } ?? "Git changes unavailable · map is still usable"
                self.filter()
            }
        }
        let scope=value.usesGitIgnore ? "Git ignore + source filter" : "Source filter (no Git ignore)"
        status.stringValue=String(format:"%@ · %.2fs · %@ · %d excluded%@",demo ? "SYNTHETIC DEMO" : "Indexed",value.seconds,scope,value.skipped,value.limited ? " · LIMIT REACHED" : "")
        if value.files.isEmpty { status.stringValue="No supported files found. Choose another folder." }
        if let error=map.rendererError { status.stringValue="Metal renderer failed: \(error)" }
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func filter() {
        guard let index else { return }
        let q=search.stringValue
        let category=kindFilter.indexOfSelectedItem
        matching=index.files.indices.filter { id in
            (category==0 || (category==1 && [.code,.html].contains(index.files[id].kind)) || (category==2 && index.files[id].kind == .image) || (category==3 && [.video,.audio].contains(index.files[id].kind)) || (category==4 && [.pdf,.document].contains(index.files[id].kind))) &&
            (q.isEmpty || index.files[id].path.localizedCaseInsensitiveContains(q)) &&
            (changesOnly.state != .on || gitChanges?.statuses[index.files[id].path] != nil) && (usageHits == nil || usageHits?[id] != nil)
        }
        map.visibleMatches=(q.isEmpty && category==0 && changesOnly.state != .on && usageHits == nil) ? nil : Set(matching)
        table.reloadData()
        if !q.isEmpty { metrics.stringValue="\(matching.count.formatted()) matches / \(index.files.count.formatted()) files" }
        else { metrics.stringValue="\(index.files.count.formatted()) files · \(ByteCountFormatter.string(fromByteCount:Int64(index.files.reduce(0){$0+$1.bytes}),countStyle:.file))" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matching.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index, matching.indices.contains(row) else { return nil }
        let identifier=NSUserInterfaceItemIdentifier("fileCell")
        let cell=(tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier=identifier
        if cell.textField == nil {
            let text=NSTextField(labelWithString:""); text.maximumNumberOfLines=2; text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints=false
            cell.addSubview(text); cell.textField=text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        }
        let file=index.files[matching[row]], url=URL(fileURLWithPath:index.files[matching[row]].path)
        let text=NSMutableAttributedString(string:url.lastPathComponent,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor])
        let detail=usageHits?[matching[row]].map { "\($0) occurrences" } ?? gitChanges?.statuses[file.path].map { "Git \($0.trimmingCharacters(in:.whitespaces))" } ?? ([ContentKind.code,.html].contains(file.kind) ? "\(file.lines) lines" : ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file))
        text.append(NSAttributedString(string:"\n\(detail) · \(file.path)",attributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor]))
        cell.textField?.attributedStringValue=text; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectionFromMap, matching.indices.contains(table.selectedRow) else { return }
        select(matching[table.selectedRow],fromMap:false)
    }
    func select(_ id: Int, fromMap: Bool, revealInspector:Bool=true) {
        guard let index, index.files.indices.contains(id) else { return }
        if revealInspector && inspectorPanel.isHidden { inspectorPanel.isHidden=false; mainSplit.adjustSubviews() }
        selectedID=id; map.selected=id; let file=index.files[id]
        fileTitle.stringValue=URL(fileURLWithPath:file.path).lastPathComponent
        fileMeta.stringValue="\(file.path)\n\(file.lines.formatted()) lines · \(file.bytes.formatted()) bytes · \(file.language.uppercased())"
        if fromMap, let row=matching.firstIndex(of:id) {
            selectionFromMap=true; table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); selectionFromMap=false
        }
        source.string="Loading source…"; map.selectedSource=""; outlinePicker.isEnabled=false
        if ![ContentKind.code,.html].contains(file.kind) {
            source.string="\(file.kind.rawValue.capitalized) · \(ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file))\n\nChoose Preview to view this file here, or Open to use its usual app."
            sourceStatus.stringValue="Original file · read only"; linksPicker.isEnabled=false; return
        }
        let generation=self.generation
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let data=try? RepoIndexer.readSource(root:index.root,path:file.path,limit:128*1024)
            let text=data.map { String(decoding:$0.prefix(128*1024),as:UTF8.self) }
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.selectedID == id else { return }
                let content=self.demo ? Self.demoSource(file) : text
                self.source.string=content ?? "Source unavailable or excluded. Refresh the index if the file moved."
                if let content { self.source.textStorage?.setAttributedString(SourceStyle.highlight(content)) }
                self.map.selectedSource=content.map { String($0.prefix(24_000)) } ?? ""
                self.source.scrollToBeginningOfDocument(nil)
                self.sourceStatus.stringValue=(file.bytes>128*1024 ? "Preview limited to 128 KiB · " : "") + "Read only · lexical outline, not resolved definitions/references"
                self.makeOutline(content ?? "")
                let links=ImportLinks.find(source:content ?? "",file:file,files:index.files)
                self.linkIDs=links.resolved; self.linksPicker.removeAllItems(); self.linksPicker.addItem(withTitle:"Imports · \(links.resolved.count) local · \(links.unresolved.count) unresolved")
                links.resolved.forEach { self.linksPicker.addItem(withTitle:index.files[$0].path) }; self.linksPicker.isEnabled = !links.resolved.isEmpty
            }
        }
    }
    func makeOutline(_ content: String) {
        outlinePicker.removeAllItems(); outlinePicker.addItem(withTitle:"Outline · lexical declarations"); outlineLines=[0]
        let pattern="^\\s*(?:(?:public|private|internal|fileprivate|open|static|final|export|async|pub|mut|unsafe)\\s+)*(?:func|fn|def|class|struct|enum|protocol|interface|function|trait|actor)\\s+[A-Za-z_][A-Za-z0-9_]*"
        let regex=try! NSRegularExpression(pattern:pattern)
        for (line,slice) in content.components(separatedBy:"\n").enumerated() {
            if regex.firstMatch(in:slice,range:NSRange(slice.startIndex...,in:slice)) != nil {
                outlinePicker.addItem(withTitle:"\(line+1)  \(slice.trimmingCharacters(in:.whitespaces).prefix(90))"); outlineLines.append(line)
                if outlineLines.count>=201 { break }
            }
        }
        outlinePicker.isEnabled=outlineLines.count>1
    }
    @objc func jumpOutline() {
        guard outlineLines.indices.contains(outlinePicker.indexOfSelectedItem) else { return }
        let line=outlineLines[outlinePicker.indexOfSelectedItem]
        let lines=source.string.components(separatedBy:"\n")
        let offset=lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
        source.setSelectedRange(NSRange(location:offset,length:0)); source.scrollRangeToVisible(NSRange(location:offset,length:0))
    }
    @objc func jumpLink() { let n=linksPicker.indexOfSelectedItem-1; if linkIDs.indices.contains(n) { let id=linkIDs[n]; select(id,fromMap:true); map.focus(id) } }
    @objc func clearUsages() { usageTask?.cancel(); usageHits=nil; symbolField.stringValue=""; filter() }
    @objc func findUsages() {
        guard let index else { return }
        var symbol=symbolField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if symbol.isEmpty, source.selectedRange().length>0 { symbol=(source.string as NSString).substring(with:source.selectedRange()); symbolField.stringValue=symbol }
        guard symbol.range(of:#"^[A-Za-z_][A-Za-z0-9_]{1,100}$"#,options:.regularExpression) != nil else { sourceStatus.stringValue="Enter an identifier, or select one in the source. Occurrences are textual, not semantic references."; return }
        usageTask?.cancel(); let token=Cancellation(); usageTask=token; let request=generation
        sourceStatus.stringValue="Finding textual occurrences…"; let sought=symbol
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var hits:[Int:Int]=[:]; var scanned=0
            for id in index.files.indices {
                if token.cancelled || scanned>=5000 { break }; scanned += 1
                guard let data=try? RepoIndexer.readSource(root:index.root,path:index.files[id].path) else { continue }
                let count=SymbolOccurrences.count(sought,in:String(decoding:data,as:UTF8.self)); if count>0 { hits[id]=count }
            }
            DispatchQueue.main.async {
                guard let self, self.generation==request, !token.cancelled else { return }
                self.usageHits=hits; self.filter(); self.sourceStatus.stringValue="Text occurrences in \(hits.count) files · scanned \(scanned)/\(index.files.count). Includes comments/strings; not semantic references."
            }
        }
    }
    func probeKernel() {
        guard verificationRoots == nil else {return}
        if demo { kernelStatus.stringValue="Synthetic preview\nNo personal data loaded"; return }
        var request=URLRequest(url:URL(string:"http://127.0.0.1:5102/api/v2/capabilities")!); request.timeoutInterval=4
        let configuration=URLSessionConfiguration.ephemeral; configuration.urlCache=nil
        URLSession(configuration:configuration).dataTask(with:request) { [weak self] data,response,error in
            let status: String
            if let r=response as? HTTPURLResponse, r.statusCode==200, let data, let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], object["contract_version"] as? String == "kernel.v3" {
                let caps=object["capabilities"] as? [String:Any]; let pack=caps?["context_pack"] as? [String:Any]
                status="● Live kernel · kernel.v3\n\(pack?["contract"] as? String ?? "ContextPack unavailable")\nCapabilities only · no life data read"
            } else if let r=response as? HTTPURLResponse, [401,403].contains(r.statusCode) {
                status="Personal service reachable\nAuthorization required"
            } else { status="Personal service unavailable\nSource maps still work offline" }
            DispatchQueue.main.async { self?.kernelStatus.stringValue=status }
        }.resume()
    }
    @objc func showAbout() {
        let alert=NSAlert(); alert.messageText="Code Atlas 0.3.2"
        let info=Bundle.main.infoDictionary ?? [:]
        alert.informativeText="Native source explorer · private local build\n\(map.gpuName)\nBuild: \(info["AtlasBuildTime"] ?? "development")\nRevision: \(info["AtlasRevision"] ?? "uncommitted")\n\nInstanced Metal map, bounded source previews. No graph file access, analytics, or external network services."
        alert.runModal()
    }
    func loadDemo() {
        cancel?.cancel(); finishScan(); requestedRoot=nil
        demo=true
        generation=UUID()
        let groups=["engine","interface","index","connectors","tests","runtime","tools"]
        let files=(0..<460).map { i in SourceFile(path:"\(groups[i % groups.count])/\(["core","models","views","support"][i%4])/\(["Renderer","Camera","Repository","Layout","Source","Search","Session"][i%7])\(i).swift",lines:24+(i*137)%1600,bytes:4000) }
        let index=RepositoryIndex(root:URL(fileURLWithPath:"/Synthetic Demo"),files:files)
        display(index,layout:Treemap.layout(files)); titleLabel.stringValue="Synthetic Demo"
        rootPicker.insertItem(withTitle:"Synthetic Demo",at:rootPicker.numberOfItems); rootPicker.selectItem(at:rootPicker.numberOfItems-1)
    }
    static func demoSource(_ file: SourceFile) -> String {
        "// Synthetic source — generated for UI verification\nimport Foundation\n\nstruct \(URL(fileURLWithPath:file.path).deletingPathExtension().lastPathComponent) {\n    let name: String\n    let count: Int\n\n    func render() -> String {\n        return name\n    }\n}\n\n" + (0..<40).map { "// Example source line \($0+15)" }.joined(separator:"\n")
    }
}

if CommandLine.arguments.contains("--verify-project-ui") {
    do {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("CodeAtlas-Folder-Verification-"+UUID().uuidString)
        let documents=base.appendingPathComponent("Atlas Test Documents"), small=base.appendingPathComponent("Atlas Test Small")
        for (folder,count) in [(documents,50),(small,2)] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for n in 0..<count {
                let content="// Generated folder-switch verification fixture\nstruct Fixture\(n) {\n"+(0..<120).map {"    // Fixture line \($0)\n"}.joined()+"}\n"
                try content.write(to:folder.appendingPathComponent("Fixture\(n).swift"),atomically:true,encoding:.utf8)
            }
        }
        let app=NSApplication.shared
        let delegate=AppDelegate(verificationRoots:[documents,small]);app.delegate=delegate;app.run()
    } catch {print("Folder verification fixtures could not be created.");exit(1)}
} else if CommandLine.arguments.contains("--verify-preview-ui") || Bundle.main.bundleIdentifier == "local.codeatlas.verification" {
    let app=NSApplication.shared
    let verifier=PreviewVerification();app.delegate=verifier;app.run()
} else if CommandLine.arguments.contains("--check-preview-layout") {
    checkPreviewLayout()
} else if CommandLine.arguments.contains("--check-personal") {
    Task.detached {
        do {
            let result=try await PersonalClient().load(query:"Personal life areas, goals, and responsibilities",token:"")
            print("personal_projection_valid=true areas=\(result.areas.count) relationships=\(result.links.count) scalar_claims=\(result.areas.reduce(0){$0+$1.claims.count})")
            exit(0)
        } catch { print("personal_projection_valid=false error=\(type(of:error))"); exit(1) }
    }
    dispatchMain()
} else if let flag=CommandLine.arguments.firstIndex(of:"--audit"), CommandLine.arguments.count>flag+1 {
    do {
        let index=try RepoIndexer.scan(URL(fileURLWithPath:CommandLine.arguments[flag+1]))
        let layout=Treemap.layout(index.files)
        print("files=\(index.files.count) lines=\(index.lines) tiles=\(layout.tiles.count) skipped=\(index.skipped) limited=\(index.limited) seconds=\(String(format:"%.3f",index.seconds)) gitIgnore=\(index.usesGitIgnore)")
    } catch { print("Index failed: \(error.localizedDescription)"); exit(1) }
} else {
    let app=NSApplication.shared
    let delegate=AppDelegate(); app.delegate=delegate; app.run()
}
