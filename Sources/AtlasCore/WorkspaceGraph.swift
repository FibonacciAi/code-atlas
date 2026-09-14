import Foundation

/// A bounded, deterministic relationship view shared by Map, City, and native
/// selection. Context nodes contain only the already projected Personal data.
public struct WorkspaceGraph: Sendable {
    public struct Node: Sendable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let fileID: Int?
        public let contextID: String?
        public let folderPath: String?
        public init(id: String, title: String, kind: String, fileID: Int? = nil, contextID: String? = nil, folderPath:String? = nil) {
            self.id = id; self.title = title; self.kind = kind; self.fileID = fileID; self.contextID = contextID; self.folderPath=folderPath
        }
    }
    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public let label: String
        public init(from: String, to: String, label: String) { self.from = from; self.to = to; self.label = label }
    }

    public let nodes: [Node]
    public let edges: [Edge]
    public let summary: String
    /// Mermaid aliases are intentionally generated rather than derived from paths.
    public let aliasToNodeID: [String: String]
    public var nodeIDByAlias: [String: String] { aliasToNodeID }
    public private(set) var pageCount=1
    public private(set) var page=0
    public let totalNodeCount: Int
    public let totalEdgeCount: Int
    public let truncatedNodeCount: Int
    public let truncatedEdgeCount: Int
    private let scanSummary: String

    private init(nodes: [Node], edges: [Edge], totalNodes: Int, totalEdges: Int, truncatedNodes: Int, truncatedEdges: Int, scanSummary: String) {
        self.nodes = nodes; self.edges = edges
        self.totalNodeCount = totalNodes; self.totalEdgeCount = totalEdges
        self.truncatedNodeCount = truncatedNodes; self.truncatedEdgeCount = truncatedEdges
        self.scanSummary = scanSummary
        self.aliasToNodeID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ("n\($0.offset)", $0.element.id) })
        var parts = ["\(nodes.count) of \(totalNodes) nodes", "\(edges.count) of \(totalEdges) edges"]
        if truncatedNodes > 0 { parts.append("\(truncatedNodes) nodes outside this display page") }
        if truncatedEdges > 0 { parts.append("\(truncatedEdges) edges outside this display page") }
        parts.append(scanSummary)
        self.summary = parts.joined(separator: " · ")
    }

    public static func build(index: RepositoryIndex, fileIDs: [Int], sources: [Int: String], projection: PersonalProjection? = nil, selectedFileID: Int? = nil, maxNodes: Int = 100, selectedNeighborhoodOnly: Bool = false, relationships:RelationshipIndex? = nil, folder:String? = nil, page:Int = 0) -> WorkspaceGraph {
        let limit = min(100, max(0, maxNodes))
        var requestedIDs = Set(fileIDs.filter { index.files.indices.contains($0) })
        if let selectedFileID, index.files.indices.contains(selectedFileID) { requestedIDs.insert(selectedFileID) }
        let validFiles = Array(requestedIDs).sorted { index.files[$0].path < index.files[$1].path }
        var allNodes = validFiles.map { fileNode(index.files[$0], id: $0) }
        var allEdges: [Edge] = []
        var seenEdges = Set<String>()
        var importCandidates = 0
        var evidenceLinks = 0
        func add(_ edge: Edge) { let key = "\(edge.from)\u{1f}\(edge.to)\u{1f}\(edge.label)"; if seenEdges.insert(key).inserted { allEdges.append(edge) } }

        let fileSet = Set(validFiles)
        if let relationships {
            let allowed=Set(validFiles.map {"file:"+index.files[$0].path})
            for edge in relationships.edges where allowed.contains(edge.from) && allowed.contains(edge.to) {
                add(edge);if edge.label.hasPrefix("import candidate") {importCandidates += 1}
            }
        }
        for id in (relationships == nil ? validFiles : []) {
            guard let source = sources[id] else { continue }
            let links = ImportLinks.find(source: source, file: index.files[id], files: index.files)
            for target in links.resolved where fileSet.contains(target) { importCandidates += 1; add(Edge(from: "file:\(index.files[id].path)", to: "file:\(index.files[target].path)", label: "import candidate")) }
            for target in markdownTargets(source: source, file: index.files[id], index: index) where fileSet.contains(target) {
                add(Edge(from: "file:\(index.files[id].path)", to: "file:\(index.files[target].path)", label: "links"))
            }
        }

        if let projection {
            var byID: [String: PersonalArea] = [:]
            for area in projection.areas where byID[area.id] == nil { byID[area.id] = area }
            let areas = byID.values.sorted { $0.id < $1.id }
            for area in areas {
                let node = Node(id: "context:\(area.id)", title: area.name, kind: area.kind, contextID: area.id)
                allNodes.append(node)
            }
            for link in projection.links.sorted(by: { ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind) }) {
                let from = "context:\(link.from)", to = "context:\(link.to)"
                if allNodes.contains(where: { $0.id == from }) && allNodes.contains(where: { $0.id == to }) { add(Edge(from: from, to: to, label: link.kind)) }
            }
            for area in areas {
                let context = "context:\(area.id)"
                for reference in area.sources {
                    // Evidence can connect only through the exact indexed-reference contract.
                    guard let fileID = IndexedSourceReference.fileID(reference, in: index), fileSet.contains(fileID) else { continue }
                    evidenceLinks += 1
                    add(Edge(from: context, to: "file:\(index.files[fileID].path)", label: "evidence"))
                }
            }
        }

        allNodes.sort {$0.id<$1.id}
        allEdges.sort {($0.from,$0.to,$0.label)<($1.from,$1.to,$1.label)}
        let fullNodes=allNodes.count, fullEdges=allEdges.count
        let coverage=relationships?.summary ?? "bounded scan of \(sources.count) readable sources"
        var detail="\(importCandidates) lexical import candidates · \(evidenceLinks) supplied evidence links"
        if selectedNeighborhoodOnly,let selectedFileID,let selected=allNodes.first(where:{$0.fileID==selectedFileID}) {
            var connected=Set([selected.id])
            for edge in allEdges {
                if edge.from==selected.id {connected.insert(edge.to)}
                if edge.to==selected.id {connected.insert(edge.from)}
            }
            allNodes=allNodes.filter {connected.contains($0.id)}
            allEdges=allEdges.filter {connected.contains($0.from) && connected.contains($0.to)}
            allNodes.sort {a,b in a.id != b.id && (a.id==selected.id || (b.id != selected.id && a.id<b.id))}
            detail="Selected file + direct neighbors · "+detail
        } else if (relationships != nil && allNodes.count>limit) || folder != nil {
            // Collapse presentation by actual folder, retaining the full relationship index.
            let prefix=folder.map {$0.isEmpty ? "":$0+"/"} ?? ""
            var mapped:[String:String]=[:], grouped:[String:Node]=[:], counts:[String:Int]=[:]
            for node in allNodes {
                guard let fileID=node.fileID else {mapped[node.id]=node.id;grouped[node.id]=node;continue}
                let path=index.files[fileID].path
                guard path.hasPrefix(prefix) else {continue}
                let relative=String(path.dropFirst(prefix.count)), pieces=relative.split(separator:"/")
                if pieces.count>1,let first=pieces.first {
                    let path=prefix+String(first),id="folder:"+path
                    mapped[node.id]=id;counts[id,default:0]+=1
                    grouped[id]=Node(id:id,title:String(first),kind:"folder",folderPath:path)
                } else {mapped[node.id]=node.id;grouped[node.id]=node}
            }
            for (id,count) in counts {if let n=grouped[id] {grouped[id]=Node(id:id,title:n.title,kind:"folder · \(count) files",folderPath:n.folderPath)}}
            var aggregates:[String:(String,String,String,Int)]=[:]
            for edge in allEdges {
                guard let from=mapped[edge.from],let to=mapped[edge.to],from != to else {continue}
                let key=from+"\u{1f}"+to+"\u{1f}"+edge.label
                let count=(aggregates[key]?.3 ?? 0)+1;aggregates[key]=(from,to,edge.label,count)
            }
            allNodes=grouped.values.sorted {$0.id<$1.id}
            allEdges=aggregates.values.map {Edge(from:$0.0,to:$0.1,label:$0.3>1 ? $0.2+" × \($0.3)":$0.2)}.sorted {($0.from,$0.to,$0.label)<($1.from,$1.to,$1.label)}
            detail="Folder overview · \(fullNodes) indexed nodes / \(fullEdges) relationships · "+detail
        }
        if relationships == nil,let selectedFileID {
            allNodes.sort {a,b in a.id != b.id && (a.fileID==selectedFileID || (b.fileID != selectedFileID && a.id<b.id))}
        }
        let totalNodes=allNodes.count,totalEdges=allEdges.count
        let size=max(1,limit), pages=max(1,(totalNodes+size-1)/size),currentPage=max(0,min(page,pages-1))
        let chosen=Array(allNodes.dropFirst(currentPage*size).prefix(limit))
        let chosenIDs=Set(chosen.map(\.id))
        let edges=allEdges.filter {chosenIDs.contains($0.from) && chosenIDs.contains($0.to)}
        let paging=pages>1 ? " · display page \(currentPage+1)/\(pages)":""
        var result=WorkspaceGraph(nodes:chosen,edges:edges,totalNodes:totalNodes,totalEdges:totalEdges,truncatedNodes:max(0,totalNodes-chosen.count),truncatedEdges:max(0,totalEdges-edges.count),scanSummary:coverage+" · "+detail+paging)
        result.pageCount=pages;result.page=currentPage
        return result
    }

    public var mermaid: String {
        var result = ["graph LR"]
        // Grouping is presentation-only; node and edge payloads stay exact.
        var groupKeys: [String] = []
        var aliasesByGroup: [String: [String]] = [:]
        for (index, node) in nodes.enumerated() {
            let key: String
            if node.fileID != nil {
                let path = node.id.dropFirst("file:".count)
                let components = path.split(separator: "/")
                key = components.dropLast().joined(separator: "/")
            } else { key = node.folderPath == nil ? "context":"folders" }
            if !groupKeys.contains(key) { groupKeys.append(key) }
            aliasesByGroup[key, default: []].append("n\(index)")
        }
        for (groupIndex, key) in groupKeys.sorted().enumerated() {
            let title = key == "context" ? "Context" : key == "folders" ? "Folders" : (key.isEmpty ? "Workspace root" : key)
            result.append("    subgraph group\(groupIndex)[\"\(Self.mermaidEscape(title))\"]")
            // A large folder should grow across the viewport rather than
            // becoming a single tall column that fit-to-window shrinks away.
            result.append("        direction LR")
            for alias in aliasesByGroup[key] ?? [] {
                guard let index = Int(alias.dropFirst()), nodes.indices.contains(index) else { continue }
                let node = nodes[index]
                result.append("        \(alias)[\"\(Self.mermaidEscape(node.title)) · \(Self.mermaidEscape(node.kind))\"]")
            }
            result.append("    end")
        }
        let aliases = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, "n\($0.offset)") })
        for edge in edges {
            if let from = aliases[edge.from], let to = aliases[edge.to] {
                if edge.label.hasPrefix("import candidate") { result.append("    \(from) -.-> \(to)") }
                else { result.append("    \(from) -->|\(Self.mermaidEscape(edge.label))| \(to)") }
            }
        }
        return result.joined(separator: "\n")
    }
    public func serializedMermaid() -> String { mermaid }
    public func markdownDocument() -> String {
        "# Code Atlas graph\n\n" + summary + "\n\n```mermaid\n" + mermaid + "\n```\n"
    }

    private static func mermaidEscape(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value { case 9, 10, 13, 34, 38, 39, 40, 41, 59, 60, 62, 91, 93, 96, 92, 123, 125, 124, 35, 37, 33: return "&#x\(String(scalar.value, radix: 16));"; default: return String(scalar) }
        }.joined()
    }
    private static func fileNode(_ file: SourceFile, id: Int) -> Node { Node(id: "file:\(file.path)", title: URL(fileURLWithPath: file.path).lastPathComponent, kind: file.kind.rawValue, fileID: id) }
}

private func markdownTargets(source: String, file: SourceFile, index: RepositoryIndex) -> [Int] {
    guard let regex = try? NSRegularExpression(pattern: #"!?(?:\[[^\]]*\])\(([^)\s]+)"#) else { return [] }
    let range = NSRange(source.startIndex..., in: source)
    return regex.matches(in: source, range: range).compactMap { match in
        guard let r = Range(match.range(at: 1), in: source) else { return nil }
        var ref = String(source[r]).removingPercentEncoding ?? String(source[r])
        if let hash = ref.firstIndex(of: "#") { ref = String(ref[..<hash]) }
        guard !ref.isEmpty, !ref.hasPrefix("/"), !ref.contains("://"), !ref.lowercased().hasPrefix("mailto:") else { return nil }
        var components = file.path.split(separator: "/").dropLast().map(String.init)
        for component in ref.split(separator: "/").map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
            else { components.append(component) }
        }
        let path = components.joined(separator: "/")
        guard let id = index.files.firstIndex(where: { $0.path == path }) else { return nil }
        return id
    }
}
