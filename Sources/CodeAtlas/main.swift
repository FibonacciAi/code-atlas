import AppKit
import AtlasCore
import UniformTypeIdentifiers
import UniformTypeIdentifiers

final class Cancellation: @unchecked Sendable {
    private let lock=NSLock(); private var value=false
    func cancel() { lock.lock(); value=true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class VerificationWindow:NSWindow {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var statusItem:NSStatusItem?
    let map=MetalMap()
    let rootPicker=NSPopUpButton()
    let search=NSSearchField()
    let table=NSTableView()
    let titleLabel=NSTextField(labelWithString:"Choose a folder")
    let metrics=NSTextField(labelWithString:"Choose a project to begin")
    let status=NSTextField(labelWithString:"Local source • read only")
    let zoomLabel=NSTextField(labelWithString:"100%")
    let kernelStatus=NSTextField(wrappingLabelWithString:"Local files · connections available on request")
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
    let graphScope=NSPopUpButton()
    let changesOnly=NSButton(checkboxWithTitle:"Changed files only",target:nil,action:nil)
    let gitSummary=NSTextField(wrappingLabelWithString:"Git changes · checking…")
    let linksPicker=NSPopUpButton()
    let modePicker=NSSegmentedControl(labels:["Map","City","Graph"],trackingMode:.selectOne,target:nil,action:nil)
    /// Exclusion/limit note kept beside the file count, which survives filtering.
    var indexNotes=""
    let symbolField=NSSearchField()
    var linkIDs:[Int]=[]
    var gitChanges: GitChanges?
    var usageHits:[Int:Int]?
    var usageTask: Cancellation?
    var folderPaths:[String]=[]
    private let workspaceBadge=NSTextField(labelWithString:"One workspace · three perspectives")
    private let workspaceHost=NSView()
    private lazy var graphView=WorkspaceGraphView()
    private var graphModel:WorkspaceGraph?
    private var graphRequest=UUID()
    private var graphWork:DispatchWorkItem?
    private var graphCancellation:Cancellation?
    private var contextProjection:PersonalProjection?
    private var connections:ConnectedContextView!
    private var fileInspector:NSStackView!
    private var contextHeight:NSLayoutConstraint!
    private var selectedContextID:String?
    private var lastSpatialMode=0
    private var showingGraph:Bool {modePicker.selectedSegment == 2}
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
    private var pendingSavedView:SavedWorkspaceView?
    private var connectOnOpen=CommandLine.arguments.contains("--connect-context")
    private var showingCachedIndex=false
    private let verificationRoots:[URL]?
    private let personalLoader:((String,String) async throws -> PersonalProjection)?
    private let preferences:UserDefaults
    init(verificationRoots:[URL]?=nil, personalLoader:((String,String) async throws -> PersonalProjection)?=nil) {
        self.verificationRoots=verificationRoots
        self.personalLoader=personalLoader
        self.preferences=verificationRoots == nil ? .standard : UserDefaults(suiteName:"local.codeatlas.verification.projects")!
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance=NSAppearance(named:.darkAqua)
        makeMenu(); buildWindow()
        if let verificationRoots {
            demo=false; roots=verificationRoots; updateRoots()
            window.title="Code Atlas · Workspace Verification"
            kernelStatus.stringValue="Verification · generated local files only\nLive connections disabled"
            if let root=roots.first {load(root)}
            if CommandLine.arguments.contains("--verify-workspace-ui") {window.orderFront(nil);verifyUnifiedWorkspace()}
            else {window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)}
            return
        }
        makeStatusItem()
        if let icon=NSImage(named:"AppIcon") {NSApp.applicationIconImage=icon}
        roots=[]
        let removed=Set(self.preferences.stringArray(forKey:"removedProjectRoots") ?? [])
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
    func applicationDidBecomeActive(_ notification:Notification) { if window != nil {probeKernel()} }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func makeMenu() {
        let menu=NSMenu(); let app=NSMenuItem(); menu.addItem(app); let appMenu=NSMenu(); app.submenu=appMenu
        let about=NSMenuItem(title:"About Code Atlas",action:#selector(showAbout),keyEquivalent:""); about.target=self; appMenu.addItem(about)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Code Atlas",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file=NSMenuItem(); file.submenu=NSMenu(title:"File"); menu.addItem(file)
        let open=NSMenuItem(title:"Open Folder…",action:#selector(chooseProject),keyEquivalent:"o"); open.target=self; file.submenu?.addItem(open)
        let refreshItem=NSMenuItem(title:"Refresh",action:#selector(refresh),keyEquivalent:"r"); refreshItem.target=self; file.submenu?.addItem(refreshItem)
        file.submenu?.addItem(.separator())
        let openFile=NSMenuItem(title:"Open Selected File",action:#selector(openSelected),keyEquivalent:"\r"); openFile.target=self; file.submenu?.addItem(openFile)
        let previewFile=NSMenuItem(title:"Preview Selected File",action:#selector(previewSelected),keyEquivalent:"y"); previewFile.target=self; file.submenu?.addItem(previewFile)
        let saveView=NSMenuItem(title:"Save View",action:#selector(saveWorkspaceView),keyEquivalent:"s"); saveView.target=self; file.submenu?.addItem(saveView)
        let restoreView=NSMenuItem(title:"Restore Saved View",action:#selector(restoreWorkspaceView),keyEquivalent:"s"); restoreView.keyEquivalentModifierMask=[.command,.option]; restoreView.target=self; file.submenu?.addItem(restoreView)
        let exportGraph=NSMenuItem(title:"Export Graph…",action:#selector(exportGraph),keyEquivalent:"e"); exportGraph.target=self; file.submenu?.addItem(exportGraph)
        let showFolder=NSMenuItem(title:"Show Folder in Finder",action:#selector(revealProject),keyEquivalent:"r")
        showFolder.keyEquivalentModifierMask=[.command,.shift]; showFolder.target=self; file.submenu?.addItem(showFolder)
        let showFile=NSMenuItem(title:"Show Selected File in Finder",action:#selector(revealSelected),keyEquivalent:""); showFile.target=self; file.submenu?.addItem(showFile)
        let edit=NSMenuItem(); edit.submenu=NSMenu(title:"Edit"); menu.addItem(edit)
        edit.submenu?.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.submenu?.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.submenu?.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let find=NSMenuItem(title:"Find File",action:#selector(focusSearch),keyEquivalent:"f"); find.target=self; edit.submenu?.addItem(find)
        let copyPath=NSMenuItem(title:"Copy File Path",action:#selector(copySelectedPath),keyEquivalent:"c")
        copyPath.keyEquivalentModifierMask=[.command,.shift]; copyPath.target=self; edit.submenu?.addItem(copyPath)
        let view=NSMenuItem();view.submenu=NSMenu(title:"View");menu.addItem(view)
        let viewCommands:[(String,Selector,String,NSEvent.ModifierFlags)]=[
            ("Map",#selector(showMap),"m",[.command,.option]),
            ("City",#selector(showCity),"c",[.command,.option]),
            ("Graph",#selector(showGraph),"g",[.command,.option]),
            ("Connections",#selector(openConnections),"k",[.command,.option]),
            ("Fit",#selector(fit),"0",[.command]),
            ("Back",#selector(goBack),"[",[.command]),
            ("Show Inspector",#selector(toggleInspector),"i",[.command,.option])
        ]
        for (title,action,key,mask) in viewCommands {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key)
            item.keyEquivalentModifierMask=mask; item.target=self; view.submenu?.addItem(item)
        }
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
        if verificationRoots != nil {
            window=VerificationWindow(contentRect:NSRect(x:100,y:80,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.ignoresMouseEvents=true
        } else {
            window=NSWindow(contentRect:NSRect(x:100,y:80,width:1440,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        }
        window.isReleasedWhenClosed=false; window.title="Code Atlas"; window.minSize=NSSize(width:1180,height:780); window.titlebarAppearsTransparent=true
        window.delegate=self
        window.backgroundColor=NSColor(calibratedRed:0.035,green:0.048,blue:0.067,alpha:1)
        let whole=NSStackView(); whole.orientation = .vertical; whole.spacing=0
        pin(whole,to:window.contentView!)
        let toolbar=NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing=8; toolbar.edgeInsets=NSEdgeInsets(top:14,left:20,bottom:14,right:20)
        let brand=label("◈  CODE ATLAS",size:14,color:.labelColor); brand.font = .systemFont(ofSize:14,weight:.bold)
        toolbar.addArrangedSubview(brand)
        let spacer=NSView(); toolbar.addArrangedSubview(spacer); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        workspaceBadge.font = .systemFont(ofSize:11,weight:.medium);workspaceBadge.textColor = .secondaryLabelColor
        toolbar.addArrangedSubview(workspaceBadge)
        whole.addArrangedSubview(toolbar);toolbar.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        let fileTools=NSStackView();fileTools.spacing=8;fileTools.edgeInsets=NSEdgeInsets(top:0,left:20,bottom:10,right:20)
        rootPicker.target=self; rootPicker.action=#selector(rootChanged); rootPicker.widthAnchor.constraint(equalToConstant:230).isActive=true
        fileTools.addArrangedSubview(rootPicker);fileTools.addArrangedSubview(button("Open Folder…",#selector(chooseProject)))
        fileTools.addArrangedSubview(button("Refresh",#selector(refresh)))
        let toolsGap=NSView();toolsGap.setContentHuggingPriority(.defaultLow,for:.horizontal);fileTools.addArrangedSubview(toolsGap)
        modePicker.target=self; modePicker.action=#selector(modeChanged); modePicker.selectedSegment=0
        modePicker.setAccessibilityLabel("Workspace view: Map, City, or Graph"); fileTools.addArrangedSubview(modePicker)
        fileTools.addArrangedSubview(button("Fit",#selector(fit)));zoomLabel.widthAnchor.constraint(equalToConstant:48).isActive=true;zoomLabel.alignment = .right;fileTools.addArrangedSubview(zoomLabel)
        fileTools.addArrangedSubview(button("Inspector",#selector(toggleInspector)))
        fileTools.addArrangedSubview(button("Connections",#selector(openConnections)))
        whole.addArrangedSubview(fileTools);fileTools.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        let split=NSSplitView(); split.isVertical=true; split.dividerStyle = .thin
        mainSplit=split
        workspaceHost.wantsLayer=true
        whole.addArrangedSubview(workspaceHost);workspaceHost.widthAnchor.constraint(equalTo:whole.widthAnchor).isActive=true
        workspaceHost.heightAnchor.constraint(greaterThanOrEqualToConstant:550).isActive=true
        pin(split,to:workspaceHost)
        let sidebar=NSView(); let inspector=NSView()
        inspectorPanel=inspector
        let mapContainer=NSView(); pin(map,to:mapContainer); pin(graphView,to:mapContainer); graphView.isHidden=true
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
        colors.autoenablesItems=false
        left.addArrangedSubview(NSStackView(views:[backButton,colors]))
        changesOnly.target=self; changesOnly.action=#selector(changeFilter); sizing.addItems(withTitles:["Size · balanced","Size · lines of code","Size · bytes","Size · equal tiles"]); sizing.target=self; sizing.action=#selector(resizeMap)
        kindFilter.addItems(withTitles:["All content","Code & HTML","Photos","Video & audio","Documents"]); kindFilter.target=self; kindFilter.action=#selector(changeFilter)
        graphScope.addItems(withTitles:["Graph · all files","Graph · selection + neighbors"])
        graphScope.target=self;graphScope.action=#selector(changeGraphScope);graphScope.isHidden=true
        left.addArrangedSubview(graphScope);graphScope.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
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
        kernelStatus.font = .systemFont(ofSize:11); kernelStatus.textColor = .secondaryLabelColor; left.addArrangedSubview(kernelStatus)
        kernelStatus.widthAnchor.constraint(equalTo:left.widthAnchor).isActive=true
        let right=NSStackView(); right.orientation = .vertical; right.alignment = .leading; right.spacing=12
        fileInspector=right
        let inspectorStack=NSStackView(); inspectorStack.orientation = .vertical; inspectorStack.spacing=12
        pin(inspectorStack,to:inspector,inset:16)
        inspectorStack.addArrangedSubview(right); right.widthAnchor.constraint(equalTo:inspectorStack.widthAnchor).isActive=true
        if let personalLoader {connections=ConnectedContextView(loader:personalLoader)}
        else if verificationRoots != nil || demo {connections=ConnectedContextView(loader:{_,_ in throw ProjectionError.unavailable})}
        else {connections=ConnectedContextView()}
        inspectorStack.addArrangedSubview(connections); connections.widthAnchor.constraint(equalTo:inspectorStack.widthAnchor).isActive=true
        contextHeight=connections.heightAnchor.constraint(equalToConstant:210)
        connections.isHidden=true
        configureConnections()

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
        right.addArrangedSubview(sourceScroll); sourceScroll.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true; sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true
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
        map.onCamera={ [weak self] value in guard let self,!self.showingGraph else {return};self.zoomLabel.stringValue=value }
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
    @objc func modeChanged(_ control:NSSegmentedControl) {setView(control.selectedSegment)}
    @objc func showMap() {setView(0)}
    @objc func showCity() {setView(1)}
    @objc func showGraph() {setView(2)}
    private func setView(_ mode:Int) {
        if mode != modePicker.selectedSegment {map.closeReader()}
        modePicker.selectedSegment=mode
        graphScope.isHidden=mode != 2
        graphView.isHidden=mode != 2;map.isHidden=mode == 2
        if mode == 2 {
            map.suspendInteraction();zoomLabel.stringValue="Graph"
            if let graphModel {graphView.select(selectedContextID.map {"context:"+$0} ?? selectedID.flatMap {id in index.map {"file:"+$0.files[id].path}});status.stringValue=graphModel.summary}
            else {scheduleGraph()}
        } else {if mode != lastSpatialMode {map.setCity(mode == 1);lastSpatialMode=mode};map.invalidate();window.makeFirstResponder(map)}
        for control in [colors,sizing,folderPicker] {control.isEnabled=mode != 2}
        backButton.isEnabled=mode != 2
    }
    @objc func revealSelected() {
        guard let index, let selectedID, let url=try? RepoIndexer.validatedURL(root:index.root,path:index.files[selectedID].path) else {
            status.stringValue="Select a file first."; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc func copySelectedPath() {
        guard let index, let selectedID else { status.stringValue="Select a file first."; return }
        let file=index.files[selectedID]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(index.root.appendingPathComponent(file.path).path,forType:.string)
        status.stringValue="Copied path · \(file.path)"
    }
    @objc func fit() { if showingGraph {graphView.fit()} else {map.fit()} }
    @objc func focusSearch() {window.makeFirstResponder(search)}
    @objc func focusSelected() { if let selectedID,let index {if showingGraph {graphView.focus("file:"+index.files[selectedID].path)} else {map.focus(selectedID)}} }
    @objc func goBack() { if showingGraph {graphView.fit()} else {map.goBack()} }
    @objc func jumpFolder() { if folderPaths.indices.contains(folderPicker.indexOfSelectedItem) { map.focusFolder(folderPaths[folderPicker.indexOfSelectedItem]) } }
    @objc func focusFolder() { if let index, let selectedID { map.focusFolder((index.files[selectedID].path as NSString).deletingLastPathComponent) } }
    @objc func toggleInspector() { inspectorPanel.isHidden.toggle(); mainSplit.adjustSubviews() }
    @objc func colorChanged() { map.colorMode=colors.indexOfSelectedItem }
    @objc func previewSelected() {if let selectedID {if showingGraph {graphView.open("file:"+(index?.files[selectedID].path ?? ""))} else {map.openFile(selectedID)}}}
    @objc func openSelected() {
        guard let index, let selectedID, let url=try? RepoIndexer.validatedURL(root:index.root,path:index.files[selectedID].path) else {return}
        NSWorkspace.shared.open(url)
    }
    @objc func resizeMap() {
        guard let index else {return}
        map.load(index,layout:Treemap.layout(index.files,sizing:AtlasSizing(rawValue:sizing.indexOfSelectedItem) ?? .balanced)); filter()
    }
    @objc func changeFilter() { filter() }
    @objc func saveWorkspaceView() {
        let selectedPath = selectedID.flatMap { id in index?.files.indices.contains(id) == true ? index?.files[id].path : nil }
        var view = SavedWorkspaceView.capture(rootPath: index?.root.path,
            viewMode: modePicker.selectedSegment, searchText: search.stringValue,
            kindFilter: kindFilter.indexOfSelectedItem, changesOnly: changesOnly.state == .on,
            sizing: sizing.indexOfSelectedItem, colorMode: colors.indexOfSelectedItem,
            selectedFilePath: selectedPath)
        view.graphScope=graphScope.indexOfSelectedItem
        SavedWorkspaceViewStore.save(view, to: preferences)
        status.stringValue = "View saved locally · no source or Personal data stored"
    }
    @objc func restoreWorkspaceView() {
        guard let saved = SavedWorkspaceViewStore.load(from: preferences) else {
            status.stringValue = "No saved view yet. Save a view from the File menu."
            return
        }
        pendingSavedView = saved
        if let path = saved.rootPath, let root = roots.first(where: { $0.path == path }) {
            load(root)
        } else if saved.rootPath == nil || saved.rootPath?.isEmpty == true {
            pendingSavedView=nil;applySavedWorkspaceView(saved)
        } else {
            pendingSavedView = nil
            status.stringValue = "Saved folder is unavailable on this Mac. Choose it again, then save a new view."
        }
    }
    private func applySavedWorkspaceView(_ saved: SavedWorkspaceView) {
        graphScope.selectItem(at:min(1,max(0,saved.graphScope ?? 0)))
        search.stringValue = saved.searchText
        kindFilter.selectItem(at: saved.kindFilter)
        changesOnly.state = saved.changesOnly ? .on : .off
        sizing.selectItem(at: saved.sizing)
        colors.selectItem(at: saved.colorMode)
        map.colorMode = saved.colorMode
        resizeMap()
        if let path = saved.selectedFilePath, let index,
           let id = index.files.firstIndex(where: { $0.path == path }) { select(id, fromMap: true) }
        setView(min(2, max(0, saved.viewMode)))
        status.stringValue = "Saved view restored locally"
    }
    @objc func exportGraph() {
        guard contextProjection == nil else {
            status.stringValue = "Graph export is unavailable while Personal is connected. Use Clear in Connections first; connected data stays on this Mac."
            return
        }
        guard let model = graphModel, model.nodes.allSatisfy({ $0.contextID == nil }) else {
            status.stringValue = "Show the file-only Graph view before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "code-atlas-graph.md"
        panel.message = "Export file relationships only. Connected Personal data cannot be exported."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                try model.markdownDocument().write(to: url, atomically: true, encoding: .utf8)
                self.status.stringValue = "Graph exported · Markdown with Mermaid"
            } catch { self.status.stringValue = "Graph export failed · \(error.localizedDescription)" }
        }
    }
    @objc func openConnections() {
        inspectorPanel.isHidden=false;fileInspector.isHidden=true
        contextHeight.isActive=false;connections.isHidden=false
        mainSplit.adjustSubviews();connections.focusQuery()
    }
    private func configureConnections() {
        connections.onPrivacyNeeded={ [weak self] in
            guard let self else {return}
            self.window.sharingType=self.personalLoader == nil ? .none:.readOnly
        }
        connections.supportsSource={ [weak self] reference in self?.indexedSourceID(reference) != nil }
        connections.onRevealSource={ [weak self] reference in
            guard let self,let id=self.indexedSourceID(reference) else {return}
            self.select(id,fromMap:true);self.showMap();self.map.focus(id)
        }
        connections.onSelectEntity={ [weak self] id in self?.selectContext(id) }
        connections.onProjection={ [weak self] projection in
            guard let self else {return}
            self.contextProjection=projection;self.selectedContextID=nil;self.map.relatedFiles=[]
            self.workspaceBadge.stringValue=projection == nil ? "One workspace · three perspectives":"Connected · on this Mac"
            if projection == nil {
                // Drop all displayed context; a connected window remains protected for its lifetime.
                self.graphView.clear();self.graphModel=nil
            }
            if CommandLine.arguments.contains("--connect-context"),let projection {
                print("live_context_ready=true entities=\(projection.areas.count) relationships=\(projection.links.count)")
                fflush(stdout)
            }
            if let first=projection?.areas.first {self.selectContext(first.id)}
            self.scheduleGraph()
        }
        graphView.onSelect={ [weak self] nodeID in
            guard let self,let node=self.graphModel?.nodes.first(where:{$0.id==nodeID}) else {return}
            if let id=node.fileID {self.select(id,fromMap:true)}
            else if let id=node.contextID {self.selectContext(id)}
        }
        map.onGraphReaderClose={ [weak self] in self?.graphView.readerClosed() }
        graphView.onOpenFile={ [weak self] fileID, rect in
            guard let self, self.index?.files.indices.contains(fileID) == true else { return }
            guard self.showingGraph else {return}
            self.map.openFileFromGraph(fileID, rect: rect)
        }
    }
    private func selectContext(_ id:String) {
        guard contextProjection?.areas.contains(where:{$0.id==id}) == true else {return}
        selectedContextID=id;selectedID=nil;map.selected=nil;table.deselectAll(nil);openConnections();connections.showEntity(id)
        if let index,let area=contextProjection?.areas.first(where:{$0.id==id}) {
            map.relatedFiles=Set(area.sources.compactMap {IndexedSourceReference.fileID($0,in:index)})
        }
        graphView.select("context:"+id)
    }
    @objc func changeGraphScope() {
        if graphScope.indexOfSelectedItem==1,selectedID == nil,let first=matching.first {select(first,fromMap:true)}
        scheduleGraph()
    }
    private func scheduleGraph() {
        graphWork?.cancel();graphCancellation?.cancel()
        let request=UUID();graphRequest=request
        guard showingGraph else {graphModel=nil;return}
        guard let index else {graphModel=nil;graphView.clear();return}
        let ids=matching, projection=contextProjection, selected=selectedID, isDemo=demo, neighborhood=graphScope.indexOfSelectedItem==1
        let token=Cancellation();graphCancellation=token
        let work=DispatchWorkItem { [weak self] in
            guard let self,!token.cancelled,self.graphRequest==request else {return}
            self.status.stringValue="Building connections…"
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                var sources:[Int:String]=[:]
                var candidates=ids
                if let selected {candidates.removeAll {$0==selected};candidates.insert(selected,at:0)}
                // Work scales with the visible graph, not the entire folder.
                for id in candidates.prefix(80) {
                    if token.cancelled {return}
                    guard index.files.indices.contains(id) else {continue}
                    let file=index.files[id]
                    guard [.code,.html,.document].contains(file.kind) else {continue}
                    if isDemo {sources[id]=Self.demoSource(file)}
                    else if let text=try? GraphSourceReader.read(index:index,fileID:id) {sources[id]=text}
                }
                guard !token.cancelled else {return}
                let model=WorkspaceGraph.build(index:index,fileIDs:ids,sources:sources,projection:projection,selectedFileID:selected,maxNodes:100,selectedNeighborhoodOnly:neighborhood)
                DispatchQueue.main.async {
                    guard let self,!token.cancelled,self.graphRequest==request else {return}
                    self.graphModel=model
                    let chosen=self.selectedContextID.map {"context:"+$0} ?? self.selectedID.map {"file:"+index.files[$0].path}
                    self.graphView.display(model,selectedID:chosen);self.status.stringValue=model.summary
                }
            }
        }
        graphWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.16,execute:work)
    }
    private func indexedSourceID(_ source:String)->Int? {
        guard let index else {return nil}
        return IndexedSourceReference.fileID(source,in:index)
    }
    func windowWillClose(_ notification:Notification) {
        connections.clear();graphWork?.cancel();graphCancellation?.cancel();graphView.clear();map.suspendInteraction()
    }
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
        if index?.root.standardizedFileURL != root.standardizedFileURL {connections.clear();graphModel=nil;graphView.clear()}
        graphWork?.cancel();graphCancellation?.cancel()
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
                    if self.connectOnOpen,self.verificationRoots == nil,!self.demo {
                        self.connectOnOpen=false;self.showGraph();self.openConnections()
                        self.connections.search(question:"Personal life areas, goals, and responsibilities")
                    }
                case .failure(let error):
                    self.status.stringValue=self.showingCachedIndex ? "Refresh failed · cached map retained · \(error.localizedDescription)" : error.localizedDescription
                    if !self.showingCachedIndex {self.metrics.stringValue="Folder could not be indexed"}
                }
            }
        }
    }
    func display(_ value: RepositoryIndex, layout: MapLayout) {
        usageTask?.cancel(); usageHits=nil; index=value; selectedID=nil; search.stringValue=""; map.query=""; titleLabel.stringValue=ProjectIdentity.title(value.root)
        indexNotes=(value.skipped>0 || value.limited) ? " · \(value.skipped.formatted()) excluded\(value.limited ? " · limit reached" : "")" : ""
        metrics.stringValue="\(value.files.count.formatted()) files · \(ByteCountFormatter.string(fromByteCount:Int64(value.files.reduce(0){$0+$1.bytes}),countStyle:.file))"+indexNotes
        fileTitle.stringValue="Explore the map"; fileMeta.stringValue="Balanced file sizes · choose a size metric\nZoom into a file to open it"; source.string=""; map.selectedSource=""
        outlinePicker.removeAllItems(); outlinePicker.addItem(withTitle:"Outline · select a file"); outlinePicker.isEnabled=false
        linkIDs=[]; linksPicker.removeAllItems(); linksPicker.addItem(withTitle:"Imports · select a file"); linksPicker.isEnabled=false
        symbolField.isEnabled=true
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
                // Controls that depend on Git are switched off rather than left
                // clickable and inert when the folder is not inside a checkout.
                let available=changes != nil
                self.changesOnly.isEnabled=available
                if !available, self.changesOnly.state == .on { self.changesOnly.state = .off }
                self.colors.item(at:2)?.isEnabled=available
                if !available, self.colors.indexOfSelectedItem==2 { self.colors.selectItem(at:0); self.map.colorMode=0 }
                self.gitSummary.stringValue=changes.map { "\($0.statuses.count) changed source paths · \($0.deleted) deleted\nGreen added · amber edited · pink renamed" } ?? "Not inside a Git checkout · change colours and filter are off"
                self.filter()
            }
        }
        let scope=value.usesGitIgnore ? "Git ignore + source filter" : "Source filter (no Git ignore)"
        status.stringValue=String(format:"%@ · %.2fs · %@ · %d excluded%@",demo ? "SYNTHETIC DEMO" : "Indexed",value.seconds,scope,value.skipped,value.limited ? " · LIMIT REACHED" : "")
        if value.files.isEmpty { status.stringValue="No supported files found. Choose another folder." }
        if let error=map.rendererError { status.stringValue="Metal renderer failed: \(error)" }
        if let saved = pendingSavedView, saved.rootPath == value.root.path {
            pendingSavedView = nil
            DispatchQueue.main.async { [weak self] in self?.applySavedWorkspaceView(saved) }
        }
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
        scheduleGraph()
        if !q.isEmpty { metrics.stringValue="\(matching.count.formatted()) matches / \(index.files.count.formatted()) files" }
        else { metrics.stringValue="\(index.files.count.formatted()) files · \(ByteCountFormatter.string(fromByteCount:Int64(index.files.reduce(0){$0+$1.bytes}),countStyle:.file))"+indexNotes }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matching.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index, matching.indices.contains(row) else { return nil }
        let identifier=NSUserInterfaceItemIdentifier("fileCell")
        let cell=(tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier=identifier
        if cell.textField == nil {
            let text=NSTextField(labelWithString:""); text.translatesAutoresizingMaskIntoConstraints=false
            text.cell?.truncatesLastVisibleLine=true
            cell.addSubview(text); cell.textField=text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),
                text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),
                text.topAnchor.constraint(equalTo:cell.topAnchor,constant:4),
                text.bottomAnchor.constraint(lessThanOrEqualTo:cell.bottomAnchor,constant:-4)
            ])
        }
        let file=index.files[matching[row]], url=URL(fileURLWithPath:index.files[matching[row]].path)
        // Without an explicit paragraph style an attributed value ignores the
        // field's line-break mode and grows past the row, painting over its
        // neighbours. Name truncates in the middle, path from the head so the
        // most specific folders stay readable.
        let nameStyle=NSMutableParagraphStyle(); nameStyle.lineBreakMode = .byTruncatingMiddle
        let detailStyle=NSMutableParagraphStyle(); detailStyle.lineBreakMode = .byTruncatingHead
        let text=NSMutableAttributedString(string:url.lastPathComponent,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:nameStyle])
        let detail=usageHits?[matching[row]].map { "\($0) occurrences" } ?? gitChanges?.statuses[file.path].map { "Git \($0.trimmingCharacters(in:.whitespaces))" } ?? ([ContentKind.code,.html].contains(file.kind) ? "\(file.lines) lines" : ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file))
        text.append(NSAttributedString(string:"\n\(detail) · \(file.path)",attributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:detailStyle]))
        cell.textField?.maximumNumberOfLines=2
        cell.textField?.attributedStringValue=text; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectionFromMap, matching.indices.contains(table.selectedRow) else { return }
        select(matching[table.selectedRow],fromMap:false)
    }
    func select(_ id: Int, fromMap: Bool, revealInspector:Bool=true) {
        guard let index, index.files.indices.contains(id) else { return }
        if revealInspector && inspectorPanel.isHidden { inspectorPanel.isHidden=false; mainSplit.adjustSubviews() }
        selectedContextID=nil;map.relatedFiles=[]
        fileInspector.isHidden=false
        connections.isHidden=contextProjection == nil
        contextHeight.isActive=contextProjection != nil
        let changedSelection=selectedID != id
        selectedID=id; map.selected=id; let file=index.files[id]
        connections.showFile(file,in:index)
        let nodeID="file:"+file.path
        if graphModel?.nodes.contains(where:{$0.id==nodeID}) == true {graphView.select(nodeID)}
        else if showingGraph {scheduleGraph()}
        if showingGraph && graphScope.indexOfSelectedItem==1 && changedSelection {scheduleGraph()}
        fileTitle.stringValue=URL(fileURLWithPath:file.path).lastPathComponent
        fileMeta.stringValue="\(file.path)\n\(file.lines.formatted()) lines · \(file.bytes.formatted()) bytes · \(file.language.uppercased())"
        if fromMap, let row=matching.firstIndex(of:id) {
            selectionFromMap=true; table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); selectionFromMap=false
        }
        source.string="Loading source…"; map.selectedSource=""
        // Clear the outline and import summaries for every selection: leaving the
        // previous file's titles in place described the wrong file.
        resetInspectorDetail(for:file)
        if ![ContentKind.code,.html].contains(file.kind) {
            source.string="\(file.kind.rawValue.capitalized) · \(ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file))\n\nChoose Preview to view this file here, or Open to use its usual app."
            sourceStatus.stringValue="Original file · read only"
            return
        }
        let generation=self.generation
        let isDemo=self.demo
        let files=index.files
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let data=try? RepoIndexer.readSource(root:index.root,path:file.path,limit:128*1024)
            let text=data.map { String(decoding:$0.prefix(128*1024),as:UTF8.self) }
            let content=isDemo ? Self.demoSource(file) : text
            // Syntax scanning, the outline, and import resolution all run here.
            // Import resolution alone compares every module against every indexed
            // path, which stalled the main thread on large folders.
            let spans=content.map { SourceStyle.spans($0,language:file.language) } ?? []
            let outline=content.map { OutlineIndex.entries($0) } ?? []
            let links=ImportLinks.find(source:content ?? "",file:file,files:files)
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.selectedID == id else { return }
                self.source.string=content ?? "Source unavailable or excluded. Refresh the index if the file moved."
                if let content { self.source.textStorage?.setAttributedString(SourceStyle.attributed(content,spans:spans)) }
                self.map.selectedSource=content.map { String($0.prefix(24_000)) } ?? ""
                self.source.scrollToBeginningOfDocument(nil)
                self.sourceStatus.stringValue=(file.bytes>128*1024 ? "Preview limited to 128 KiB · " : "") + "Read only · lexical outline, not resolved definitions/references"
                self.applyOutline(outline)
                self.applyImports(links,files:files)
            }
        }
    }
    /// Every selection starts from an empty outline and import summary.
    func resetInspectorDetail(for file: SourceFile) {
        let readable=[ContentKind.code,.html].contains(file.kind)
        outlineLines=[0]; linkIDs=[]
        outlinePicker.removeAllItems()
        outlinePicker.addItem(withTitle:readable ? "Outline · reading…" : "Outline · not available for \(file.kind.rawValue)")
        outlinePicker.isEnabled=false
        linksPicker.removeAllItems()
        linksPicker.addItem(withTitle:readable ? "Imports · reading…" : "Imports · not available for \(file.kind.rawValue)")
        linksPicker.isEnabled=false
        symbolField.isEnabled=readable
    }
    func applyOutline(_ entries:[OutlineEntry]) {
        outlinePicker.removeAllItems(); outlinePicker.addItem(withTitle:"Outline · lexical declarations"); outlineLines=[0]
        for entry in entries {
            outlinePicker.addItem(withTitle:"\(entry.line+1)  \(entry.title)"); outlineLines.append(entry.line)
        }
        outlinePicker.isEnabled=outlineLines.count>1
    }
    func applyImports(_ links:ImportLinks,files:[SourceFile]) {
        linkIDs=links.resolved
        linksPicker.autoenablesItems=false
        linksPicker.removeAllItems()
        // A package that is not in this folder is external, not a failure.
        linksPicker.addItem(withTitle:"Imports · \(links.resolved.count) local · \(links.unresolved.count) external")
        links.resolved.forEach { linksPicker.addItem(withTitle:files[$0].path) }
        if !links.unresolved.isEmpty {
            linksPicker.menu?.addItem(.separator())
            linksPicker.addItem(withTitle:"External · not in this folder")
            linksPicker.item(at:linksPicker.numberOfItems-1)?.isEnabled=false
            for module in links.unresolved {
                linksPicker.addItem(withTitle:"   \(module)")
                linksPicker.item(at:linksPicker.numberOfItems-1)?.isEnabled=false
            }
        }
        linksPicker.isEnabled = !links.resolved.isEmpty || !links.unresolved.isEmpty
    }
    @objc func jumpOutline() {
        guard outlineLines.indices.contains(outlinePicker.indexOfSelectedItem) else { return }
        let line=outlineLines[outlinePicker.indexOfSelectedItem]
        let lines=source.string.components(separatedBy:"\n")
        let offset=lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
        source.setSelectedRange(NSRange(location:offset,length:0)); source.scrollRangeToVisible(NSRange(location:offset,length:0))
    }
    @objc func jumpLink() {
        // Only the local entries, which sit directly after the summary row, navigate.
        let n=linksPicker.indexOfSelectedItem-1
        guard linkIDs.indices.contains(n) else { linksPicker.selectItem(at:0); return }
        let id=linkIDs[n]; select(id,fromMap:true); map.focus(id)
    }
    @objc func clearUsages() { usageTask?.cancel(); usageHits=nil; symbolField.stringValue=""; filter() }
    @objc func findUsages() {
        guard let index else { return }
        var symbol=symbolField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if symbol.isEmpty, source.selectedRange().length>0 { symbol=(source.string as NSString).substring(with:source.selectedRange()); symbolField.stringValue=symbol }
        guard symbol.range(of:#"^[A-Za-z_][A-Za-z0-9_]{1,100}$"#,options:.regularExpression) != nil else { sourceStatus.stringValue="Enter an identifier, or select one in the source. Occurrences are textual, not semantic references."; return }
        usageTask?.cancel(); let token=Cancellation(); usageTask=token; let request=generation
        sourceStatus.stringValue="Finding textual occurrences…"; let sought=symbol
        let anchor=selectedID.map { index.files[$0] }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            // Only readable files can contain an identifier, and the scan is capped,
            // so spend the budget on the neighbourhood of the selected file first
            // instead of burning it on whatever sorts earliest by path.
            let anchorFolder=anchor.map { ($0.path as NSString).deletingLastPathComponent }
            let anchorLanguage=anchor?.language
            func rank(_ file: SourceFile) -> Int {
                if let anchorFolder, (file.path as NSString).deletingLastPathComponent==anchorFolder { return 0 }
                if let anchorLanguage, file.language==anchorLanguage { return 1 }
                return 2
            }
            let candidates=index.files.indices
                .filter { [ContentKind.code,.html].contains(index.files[$0].kind) }
                .sorted { a,b in
                    let ra=rank(index.files[a]), rb=rank(index.files[b])
                    return ra==rb ? index.files[a].path<index.files[b].path : ra<rb
                }
            var hits:[Int:Int]=[:]; var scanned=0
            for id in candidates {
                if token.cancelled || scanned>=5000 { break }; scanned += 1
                guard let data=try? RepoIndexer.readSource(root:index.root,path:index.files[id].path) else { continue }
                let count=SymbolOccurrences.count(sought,in:String(decoding:data,as:UTF8.self)); if count>0 { hits[id]=count }
            }
            DispatchQueue.main.async {
                guard let self, self.generation==request, !token.cancelled else { return }
                self.usageHits=hits; self.filter()
                let coverage=scanned<candidates.count ? "scanned \(scanned) of \(candidates.count) readable files, nearest first" : "scanned all \(candidates.count) readable files"
                self.sourceStatus.stringValue="Text occurrences in \(hits.count) files · \(coverage). Includes comments/strings; not semantic references."
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
                status=pack?["contract"] as? String == "context-pack.v1" ? "Local connection available · use Connections to search":"Local connection needs an update"
            } else if let r=response as? HTTPURLResponse, [401,403].contains(r.statusCode) {
                status="Local connection reachable\nAuthorization required"
            } else { status="Local connection unavailable\nSource maps still work offline" }
            DispatchQueue.main.async { self?.kernelStatus.stringValue=status }
        }.resume()
    }
    @objc func showAbout() {
        let info=Bundle.main.infoDictionary ?? [:]
        let alert=NSAlert(); alert.messageText="Code Atlas \(info["CFBundleShortVersionString"] ?? "development")"
        alert.informativeText="Native spatial file explorer\n\(map.gpuName)\nBuild: \(info["AtlasBuildTime"] ?? "development")\nRevision: \(info["AtlasRevision"] ?? "uncommitted")\n\nMetal map, city, and local relationship graph. No direct graph file access, analytics, or configured cloud backend."
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
    /// Runs only with generated roots and an injected service; no live reads.
    private func verifyUnifiedWorkspace() {
        guard verificationRoots != nil,personalLoader != nil else {return}
        Task { @MainActor in
            var checks:[String:Bool]=[:]
            func pause(_ seconds:Double) async {try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))}
            @MainActor func graphState() async -> [String:Any] {await withCheckedContinuation { continuation in graphView.verifyRendering {continuation.resume(returning:$0)} }}
            @MainActor func waitForGraph() async -> [String:Any] {
                for _ in 0..<60 {
                    let state=await graphState()
                    if (state["nodeCount"] as? Int ?? 0)>0 && state["loading"] as? Bool == false {return state}
                    await pause(0.2)
                }
                return await graphState()
            }
            @MainActor func capture(_ name:String) {
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                process.arguments=["-x","-l",String(window.windowNumber),"/tmp/code-atlas-"+name+".png"]
                process.standardError=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice
                try? process.run();process.waitUntilExit()
            }
            for _ in 0..<60 {if index != nil {break};await pause(0.2)}
            checks["generated_index_loaded"]=index?.files.isEmpty == false
            guard let current=index,current.files.count>1 else {NSApp.terminate(nil);return}
            select(1,fromMap:true);showGraph()
            let initial=await waitForGraph()
            checks["offline_mermaid_rendered"]=(initial["nodeCount"] as? Int ?? 0)>0
            graphView.verifySelectFirstNode();await pause(0.3)
            checks["graph_click_selects_file"]=selectedID==graphModel?.nodes.first?.fileID
            graphView.verifyZoomOpen();await pause(0.45)
            checks["graph_zoom_opens_native_reader"]=map.hasOpenReader && showingGraph
            let beforeClose=await graphState()
            map.closeReader();await pause(0.4)
            let afterClose=await graphState()
            checks["reader_returns_to_same_graph"]=showingGraph && !map.hasOpenReader && NSDictionary(dictionary:beforeClose["camera"] as? [String:Any] ?? [:]).isEqual(to:afterClose["camera"] as? [String:Any] ?? [:])
            saveWorkspaceView();let savedMode=modePicker.selectedSegment
            showMap();restoreWorkspaceView();await pause(0.4)
            checks["saved_view_restores_mode"]=modePicker.selectedSegment==savedMode
            let selected=selectedID
            showCity();await pause(0.35);showMap();await pause(0.35)
            checks["selection_shared_across_views"]=selectedID==selected && map.selected==selected
            openConnections();connections.search(question:"Studio projects")
            for _ in 0..<30 {if connections.hasContent {break};await pause(0.2)}
            checks["context_loaded_in_shared_inspector"]=connections.hasContent && !mainSplit.isHidden && !inspectorPanel.isHidden
            showGraph();await pause(0.3);let connected=await waitForGraph()
            checks["context_and_files_in_same_graph"]=graphModel?.nodes.contains(where:{$0.contextID != nil}) == true && graphModel?.nodes.contains(where:{$0.fileID != nil}) == true
            checks["connected_graph_rendered"]=(connected["nodeCount"] as? Int ?? 0)==graphModel?.nodes.count
            selectContext("atlas");await pause(0.3)
            checks["evidence_panel_has_visible_content"]=connections.verifyLayout()
            checks["document_links_in_graph"]=graphModel?.edges.contains(where:{$0.label=="links"}) == true
            checks["entity_selection_no_recursion"]=connections.currentEntityID=="atlas" && !map.relatedFiles.isEmpty
            window.makeKeyAndOrderFront(nil);window.makeFirstResponder(nil)
            await pause(0.6)
            checks["graph_view_visible"] = !graphView.isHiddenOrHasHiddenAncestor && graphView.visibleRect.width>100 && graphView.visibleRect.height>100
            capture("unified-graph")
            if let sourceID=current.files.firstIndex(where:{$0.path=="Fixture0.swift"}) {
                select(sourceID,fromMap:true);showMap();await pause(0.4)
                checks["file_selection_restores_source_inspector"] = !fileInspector.isHidden && selectedID==sourceID
            }
            capture("unified-inspector")
            connections.search(question:"slow request");connections.clear();await pause(2.3)
            checks["clear_cancels_slow_context"] = !connections.hasContent && contextProjection==nil
            showGraph();await pause(0.3);_ = await waitForGraph()
            checks["cleared_context_removed_from_graph"]=graphModel?.nodes.allSatisfy({$0.contextID==nil}) == true
            if let other=verificationRoots?.last {load(other)}
            await pause(0.8)
            checks["folder_switch_clears_selection"]=selectedID==nil && contextProjection==nil
            let result:[String:Any]=["checks":checks,"passed":checks.values.allSatisfy({$0}),"syntheticOnly":true,"renderedNodes":initial["nodeCount"] ?? 0]
            if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:"/tmp/code-atlas-workspace-verification.json"),options:.atomic)}
            NSApp.terminate(nil)
        }
    }
    static func demoSource(_ file: SourceFile) -> String {
        "// Synthetic source — generated for UI verification\nimport Foundation\n\nstruct \(URL(fileURLWithPath:file.path).deletingPathExtension().lastPathComponent) {\n    let name: String\n    let count: Int\n\n    func render() -> String {\n        return name\n    }\n}\n\n" + (0..<40).map { "// Example source line \($0+15)" }.joined(separator:"\n")
    }
}

if CommandLine.arguments.contains("--verify-project-ui") || CommandLine.arguments.contains("--verify-personal-ui") || CommandLine.arguments.contains("--verify-workspace-ui") {
    do {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("CodeAtlas-Folder-Verification-"+UUID().uuidString)
        let documents=base.appendingPathComponent("Atlas Test Documents"), small=base.appendingPathComponent("Atlas Test Small")
        for (folder,count) in [(documents,CommandLine.arguments.contains("--verify-workspace-ui") ? 6:50),(small,2)] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for n in 0..<count {
                let content="// Generated folder-switch verification fixture\nstruct Fixture\(n) {\n"+(0..<120).map {"    // Fixture line \($0)\n"}.joined()+"}\n"
                try content.write(to:folder.appendingPathComponent("Fixture\(n).swift"),atomically:true,encoding:.utf8)
            }
        }
        if CommandLine.arguments.contains("--verify-workspace-ui") {
            try "# Fieldnotes\n\n[Renderer](Fixture0.swift) · [Plan](plan.md)\n".write(to:documents.appendingPathComponent("README.md"),atomically:true,encoding:.utf8)
            try "# Plan\nBuild a small explorer.\n[Readme](README.md)\n".write(to:documents.appendingPathComponent("plan.md"),atomically:true,encoding:.utf8)
        }
        let app=NSApplication.shared
        let loader=(CommandLine.arguments.contains("--verify-personal-ui") || CommandLine.arguments.contains("--verify-workspace-ui")) ? PersonalVerification.loader(root:documents) : nil
        let delegate=AppDelegate(verificationRoots:[documents,small],personalLoader:loader);app.delegate=delegate;app.run()
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
