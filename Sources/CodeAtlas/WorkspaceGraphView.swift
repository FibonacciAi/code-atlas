import AppKit
import WebKit
import AtlasCore

private final class WorkspaceGraphBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WorkspaceGraphView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

final class WorkspaceGraphView: NSView, WKNavigationDelegate {
    var onSelect: ((String) -> Void)?
    var onOpenFile: ((Int, CGRect) -> Void)?
    var onStatus: ((String) -> Void)?
    private let webView: WKWebView
    private let bridge: WorkspaceGraphBridge
    private var aliasToNative: [String: String] = [:]
    private var nativeToAlias: [String: String] = [:]
    private var ready = false
    private var generation = 0
    private var validFileIDs=Set<Int>()
    private var pending: [String] = []
    override var isFlipped: Bool { true }

    init() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController(); configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration); bridge = WorkspaceGraphBridge()
        super.init(frame: .zero); bridge.owner = self; controller.add(bridge, name: "atlas")
        webView.navigationDelegate = self; webView.setValue(false, forKey: "drawsBackground"); addSubview(webView); loadShell()
    }
    required init?(coder: NSCoder) { fatalError("WorkspaceGraphView does not support NSCoder") }
    override func layout() { super.layout(); webView.frame = bounds }

    func display(_ graph: WorkspaceGraph, selectedID: String? = nil) {
        generation += 1; aliasToNative = graph.aliasToNodeID; nativeToAlias = Dictionary(uniqueKeysWithValues: aliasToNative.map { ($1, $0) })
        let titles = Dictionary(uniqueKeysWithValues: graph.nodes.compactMap { node -> (String, String)? in
            guard let alias = nativeToAlias[node.id] else { return nil }; let title = node.title
            let short = URL(fileURLWithPath: title).lastPathComponent
            return (alias, String((short.isEmpty ? title : short).prefix(120)))
        })
        let fileIDs = Dictionary(uniqueKeysWithValues: graph.nodes.compactMap { node -> (String, Int)? in guard let alias = nativeToAlias[node.id], let fileID = node.fileID else { return nil }; return (alias, fileID) })
        validFileIDs=Set(fileIDs.values)
        let payload: [String: Any] = ["generation": generation, "source": graph.mermaid, "aliases": Array(aliasToNative.keys).sorted(), "titles": titles, "fileIDs": fileIDs, "selected": selectedID.flatMap { nativeToAlias[$0] } ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), case let encoded = data.base64EncodedString() else { status("The graph could not be prepared."); return }
        enqueue("window.Atlas.render('" + encoded + "');", replacingRender: true)
    }
    func select(_ id: String?) { guard let id, let alias = nativeToAlias[id] else { enqueue("window.Atlas.select(null);"); return }; enqueue("window.Atlas.select('" + Self.jsString(alias) + "');") }
    func open(_ id:String) {guard let alias=nativeToAlias[id] else {return};enqueue("window.Atlas.open('"+Self.jsString(alias)+"');")}
    func readerClosed() {enqueue("window.Atlas.readerClosed();");window?.makeFirstResponder(webView)}
    func fit() { enqueue("window.Atlas.fit();") }
    func focus(_ id: String) { guard let alias = nativeToAlias[id] else { return }; enqueue("window.Atlas.focus('" + Self.jsString(alias) + "');") }
    func clear() { generation += 1;validFileIDs.removeAll(); aliasToNative.removeAll(); nativeToAlias.removeAll(); pending.removeAll(); enqueue("window.Atlas.clear();"); status("No workspace graph loaded.") }
    func verifyRendering(_ completion: @escaping ([String: Any]) -> Void) { webView.evaluateJavaScript("window.Atlas.verify();") { value, _ in completion(value as? [String: Any] ?? [:]) } }
    func verifyZoomOpen() {enqueue("window.Atlas.verifyZoomOpen();")}
    func verifySelectFirstNode() { enqueue("window.Atlas.verifySelect();") }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == "atlas", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "select", body["generation"] as? Int == generation, let alias = body["alias"] as? String, let id = aliasToNative[alias] { onSelect?(id) }
        if type == "open", body["generation"] as? Int == generation, let fileID = body["fileID"] as? Int,validFileIDs.contains(fileID),
           let rect = body["rect"] as? [String: CGFloat], let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"], [x,y,width,height].allSatisfy({$0.isFinite}),width>0,height>0 {
            onOpenFile?(fileID, CGRect(x: x, y: y, width: width, height: height))
        }
        if type == "status", let value = body["status"] as? String { onStatus?(value) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; pending.forEach { webView.evaluateJavaScript($0) }; pending.removeAll(); onStatus?("Ready") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { status("Graph unavailable: \(error.localizedDescription)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { status("Graph unavailable: \(error.localizedDescription)") }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.navigationType == .other && (action.request.url.map { $0.isFileURL } ?? true) ? .allow : .cancel) }
    private func loadShell() {
        let packaged=Bundle.main.resourceURL?.appendingPathComponent("CodeAtlas_CodeAtlas.bundle/graph/index.html")
        let url:URL?
        if let packaged,FileManager.default.fileExists(atPath:packaged.path) {url=packaged}
        else {url=Bundle.module.url(forResource:"index",withExtension:"html",subdirectory:"graph")}
        guard let url else {status("Graph renderer resources are missing.");return}
        webView.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent())
    }
    private func enqueue(_ script: String, replacingRender: Bool = false) { if ready { webView.evaluateJavaScript(script) } else { if replacingRender { pending.removeAll { $0.contains("Atlas.render(") } }; pending.append(script) } }
    private func status(_ value: String) { onStatus?(value); enqueue("window.Atlas && window.Atlas.status('" + Self.jsString(value) + "');") }
    private static func jsString(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n") }
    private static func safeSource(_ source: String) -> String { ["<script", "javascript:", "window.webkit", "document.cookie", "click "].contains { source.localizedCaseInsensitiveContains($0) } ? "graph TB\n  empty[Graph unavailable]" : source }
}
