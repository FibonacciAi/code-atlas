import AppKit
import AtlasCore

/// Compact connected-context inspector for the existing Code Atlas inspector.
/// It only renders the supplied, bounded PersonalProjection; it never writes to
/// the kernel or exposes the raw response.
private final class ConnectedContextDetailStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class ConnectedContextView: NSView {
    typealias Loader = (String, String) async throws -> PersonalProjection

    var onProjection: ((PersonalProjection?) -> Void)?
    var onSelectEntity: ((String) -> Void)?
    var onRevealSource: ((String) -> Void)?
    var onPrivacyNeeded: (() -> Void)?
    var supportsSource: ((String) -> Bool)?
    var hasContent: Bool { projection != nil }
    var currentEntityID: String? { selectedID }

    private let loader: Loader
    private let query = NSSearchField()
    private let token = NSSecureTextField()
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Ask about this workspace to see connected evidence.")
    private let progress = NSProgressIndicator()
    private let options = NSStackView()
    private var controls:NSStackView!
    private var optionsButton:NSButton!
    private let detail = ConnectedContextDetailStack()
    private let detailScroll = NSScrollView()
    private var projection: PersonalProjection?
    private var file: SourceFile?
    private var index: RepositoryIndex?
    private var selectedID: String?
    private var generation = UUID()
    private var requestTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init(loader: @escaping Loader = { try await PersonalClient().load(query: $0, token: $1) }) {
        self.loader = loader
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed:0.055,green:0.09,blue:0.12,alpha:1).cgColor
        layer?.cornerRadius=10

        query.placeholderString = "Ask about this workspace"
        query.sendsSearchStringImmediately = false
        query.sendsWholeSearchString = true
        query.target = self
        query.action = #selector(searchAction)
        query.setAccessibilityLabel("Ask about this workspace")
        searchButton.bezelStyle = .rounded; clearButton.bezelStyle = .rounded
        searchButton.target = self
        searchButton.action = #selector(searchAction)
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.setAccessibilityLabel("Clear connected context")

        let queryRow = NSStackView(views: [query])
        queryRow.spacing = 8
        let actionRow = NSStackView(views: [searchButton, clearButton])
        actionRow.spacing = 8
        let header = NSStackView(views: [queryRow, actionRow]); controls=header
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        query.setContentHuggingPriority(.defaultLow, for: .horizontal)
        query.widthAnchor.constraint(equalTo: queryRow.widthAnchor).isActive = true

        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6
        options.isHidden = true
        optionsButton = NSButton(title: "Connection options", target: self, action: #selector(toggleOptions))
        optionsButton.bezelStyle = .rounded
        optionsButton.setAccessibilityLabel("Show connection options")
        token.placeholderString = "Optional scoped read token"
        token.setAccessibilityLabel("Optional scoped read token")
        options.addArrangedSubview(token)
        token.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 9
        detail.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 20, right: 14)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.documentView = detail
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detail.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor)
        ])

        let footer = NSStackView(views: [progress, status])
        footer.spacing = 7
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let outer = NSStackView(views: [header, optionsButton, options, footer, detailScroll])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor), outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor), outer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for view in [header, optionsButton!, options, footer, detailScroll] {
            view.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -20).isActive = true
        }
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        showMessage("Connected context", "Ask a question to inspect evidence from the selected workspace.")
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { requestTask?.cancel() }

    @objc private func toggleOptions() { options.isHidden.toggle() }

    @objc private func searchAction() { performSearch() }

    /// Starts the same bounded read as the Search button, useful for injected
    /// verification loaders and UI harnesses.
    func search(question: String) {
        query.stringValue = question
        performSearch()
    }

    private func performSearch() {
        let question = String(query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !question.isEmpty else { status.stringValue = "Enter a question first."; window?.makeFirstResponder(query); return }
        requestTask?.cancel()
        generation = UUID()
        let request = generation
        let credential = token.stringValue
        let read = loader
        projection = nil
        selectedID = nil
        onProjection?(nil)
        // Keep the current inspector detail visible while a replacement read is
        // in flight; the parent owns any source renderer shielding/clearing.
        onPrivacyNeeded?()
        status.stringValue = "Reading connected context on this Mac…"
        progress.startAnimation(nil)
        requestTask = Task { @MainActor [weak self] in
            do {
                let result = try await read(question, credential)
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.onPrivacyNeeded?()
                self.requestTask = nil
                self.progress.stopAnimation(nil)
                self.projection = result
                self.onProjection?(result)
                if let id = self.selectedID { self.renderEntity(id) }
                else if let first = result.areas.first { self.renderEntity(first.id) }
                else { self.showMessage("No matching context", "The bounded query returned no entities with evidence.") }
                self.status.stringValue = result.readSummary
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.requestTask = nil
                self.progress.stopAnimation(nil)
                self.onProjection?(nil)
                self.status.stringValue = "Connected context is unavailable right now."
                self.showMessage("Couldn’t load connected context", (error as? LocalizedError)?.errorDescription ?? "Try again with a narrower question.")
            }
        }
    }

    /// Displays only evidence whose supplied source reference resolves to this
    /// exact indexed file. No filename or semantic association is inferred.
    func showFile(_ file: SourceFile?, in index: RepositoryIndex?) {
        controls.isHidden=true;optionsButton.isHidden=true;options.isHidden=true
        self.file = file
        self.index = index
        selectedID = nil
        guard let file, let index, let projection else {
            showMessage("File context", projection == nil ? "Ask a question to match this file to supplied evidence." : "Select a source file to inspect its supplied evidence.")
            return
        }
        guard let targetID=index.files.firstIndex(where:{$0.path==file.path}) else {showMessage("File not indexed", "Select a file from this workspace.");return}
        let matches = projection.areas.filter { area in
            area.sources.contains { reference in IndexedSourceReference.fileID(reference, in: index) == targetID }
        }
        clearDetail()
        addLabel(file.path, size: 16, bold: true)
        addLabel("Evidence supplied for this exact indexed source", size: 11)
        if matches.isEmpty { addLabel("No supplied evidence references this file.") }
        for area in matches {
            addEntityButton(area)
            for claim in area.claims { addLabel(claim, size: 12) }
            for source in area.sources where IndexedSourceReference.fileID(source, in: index) == targetID { addSource(source) }
        }
        scrollTop()
    }

    func showEntity(_ id: String) {
        selectedID = id
        if projection == nil { showMessage("Entity context", "Ask a question before selecting an entity."); return }
        renderEntity(id)
    }

    func focusQuery() { controls.isHidden=false;optionsButton.isHidden=false;window?.makeFirstResponder(query) }
    func verifyLayout() -> Bool {
        layoutSubtreeIfNeeded()
        return detail.arrangedSubviews.contains {$0.frame.height>8 && $0.frame.width>40} && detailScroll.frame.height>=75
    }

    @objc func clear() {
        if let editor=window?.firstResponder as? NSTextView,editor.isFieldEditor,
           [query,token].contains(where:{$0.currentEditor() === editor}) {
            window?.makeFirstResponder(nil);editor.undoManager?.removeAllActions();editor.string=""
        }
        requestTask?.cancel(); requestTask = nil; generation = UUID()
        projection = nil; selectedID = nil; file = nil; index = nil
        query.stringValue = ""; token.stringValue = ""
        progress.stopAnimation(nil); status.stringValue = "Connected context cleared."
        onProjection?(nil)
        showMessage("Connected context", "Ask a question to inspect supplied evidence.")
    }

    private func renderEntity(_ id: String) {
        guard let area = projection?.areas.first(where: { $0.id == id }) else { showMessage("Entity unavailable", "That entity was not present in the current bounded projection."); return }
        clearDetail(); addLabel(area.name, size: 17, bold: true); addLabel(area.kind.capitalized + " · Updated " + area.updated, size: 11)
        addLabel("Evidence", size: 13, bold: true)
        if area.claims.isEmpty { addLabel("No claims were supplied for this entity.") } else { area.claims.forEach { addLabel($0, size: 12) } }
        addLabel("Sources", size: 13, bold: true)
        if area.sources.isEmpty { addLabel("No source references were supplied.") } else { area.sources.forEach { addSource($0) } }
        let links = projection?.links.filter { $0.from == id || $0.to == id } ?? []
        if !links.isEmpty { addLabel("Connections", size: 13, bold: true); for link in links { let other = link.from == id ? link.to : link.from; let button = NSButton(title: (link.from == id ? "→ " : "← ") + (link.kind.replacingOccurrences(of: "_", with: " ")) + " · " + (projection?.areas.first(where: { $0.id == other })?.name ?? other), target: self, action: #selector(entityButton(_:))); button.identifier = NSUserInterfaceItemIdentifier(other); detail.addArrangedSubview(button); constrain(button) } }
        scrollTop()
    }

    private func addEntityButton(_ area: PersonalArea) { let button = NSButton(title: area.name, target: self, action: #selector(entityButton(_:))); button.identifier = NSUserInterfaceItemIdentifier(area.id); detail.addArrangedSubview(button); constrain(button) }
    @objc private func entityButton(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue {
            if let onSelectEntity {onSelectEntity(id)} else {showEntity(id)}
        }
    }
    private func addSource(_ source: String) { let label = addLabel(URL(string: source)?.lastPathComponent ?? source, size: 11, bold: true); label.toolTip = source; if supportsSource?(source) == true { let button = NSButton(title: "Reveal source", target: self, action: #selector(sourceButton(_:))); button.identifier = NSUserInterfaceItemIdentifier(source); detail.addArrangedSubview(button); constrain(button) } }
    @objc private func sourceButton(_ sender: NSButton) { guard let source = sender.identifier?.rawValue, supportsSource?(source) == true else { return }; onRevealSource?(source) }
    @discardableResult private func addLabel(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField { let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); label.isSelectable = true; detail.addArrangedSubview(label); constrain(label); return label }
    private func constrain(_ view: NSView) { view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -28).isActive = true }
    private func clearDetail() { detail.arrangedSubviews.forEach { detail.removeArrangedSubview($0); $0.removeFromSuperview() } }
    private func showMessage(_ title: String, _ message: String) { clearDetail(); addLabel(title, size: 17, bold: true); addLabel(message); scrollTop() }
    private func scrollTop() { detail.layoutSubtreeIfNeeded(); detailScroll.contentView.scroll(to: .zero); detailScroll.reflectScrolledClipView(detailScroll.contentView) }
}
