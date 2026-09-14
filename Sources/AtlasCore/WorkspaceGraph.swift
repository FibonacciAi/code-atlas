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
        public init(id: String, title: String, kind: String, fileID: Int? = nil, contextID: String? = nil) {
            self.id = id; self.title = title; self.kind = kind; self.fileID = fileID; self.contextID = contextID
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
        if truncatedNodes > 0 { parts.append("\(truncatedNodes) nodes omitted") }
        if truncatedEdges > 0 { parts.append("\(truncatedEdges) edges omitted") }
        parts.append(scanSummary)
        self.summary = parts.joined(separator: " · ")
    }

    public static func build(index: RepositoryIndex, fileIDs: [Int], sources: [Int: String], projection: PersonalProjection? = nil, selectedFileID: Int? = nil, maxNodes: Int = 100, selectedNeighborhoodOnly: Bool = false) -> WorkspaceGraph {
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
        for id in validFiles {
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

        allNodes = allNodes.sorted { $0.id < $1.id }
        allEdges = allEdges.sorted { ($0.from, $0.to, $0.label) < ($1.from, $1.to, $1.label) }
        let totalNodes = allNodes.count, totalEdges = allEdges.count
        var keep = Set<String>()
        var priority: [String] = []
        var neighborhoodActive = false
        func prioritize(_ id: String) { if !keep.contains(id) { keep.insert(id); priority.append(id) } }
        if let selectedFileID, let selected = allNodes.first(where: { $0.fileID == selectedFileID }) {
            neighborhoodActive = selectedNeighborhoodOnly
            prioritize(selected.id)
            let neighbors = allEdges.flatMap { edge -> [String] in
                edge.from == selected.id ? [edge.to] : (edge.to == selected.id ? [edge.from] : [])
            }
            neighbors.sorted().forEach { prioritize($0) }
        }
        if !neighborhoodActive {
            // Reserve room for the connected context (up to the projection's
            // 24-area bound) before filling the remaining budget with files.
            allNodes.filter { $0.contextID != nil }.prefix(24).forEach { if keep.count < limit { prioritize($0.id) } }
            allNodes.filter { $0.fileID != nil }.forEach { if keep.count < limit { prioritize($0.id) } }
        }
        let chosenIDsInOrder = priority.prefix(limit)
        let chosen = chosenIDsInOrder.compactMap { id in allNodes.first { $0.id == id } }
        let chosenIDs = Set(chosen.map(\.id))
        // Keep the edge payload bounded by the same caller supplied budget.
        let chosenEdges = allEdges.filter { chosenIDs.contains($0.from) && chosenIDs.contains($0.to) }.prefix(limit)
        let scan = "bounded scan of \(sources.keys.filter { index.files.indices.contains($0) }.count) readable sources · \(importCandidates) lexical import candidates · \(evidenceLinks) supplied evidence links"
        return WorkspaceGraph(nodes: Array(chosen), edges: Array(chosenEdges), totalNodes: totalNodes, totalEdges: totalEdges, truncatedNodes: max(0, totalNodes - chosen.count), truncatedEdges: max(0, totalEdges - chosenEdges.count), scanSummary: scan)
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
            } else { key = "context" }
            if !groupKeys.contains(key) { groupKeys.append(key) }
            aliasesByGroup[key, default: []].append("n\(index)")
        }
        for (groupIndex, key) in groupKeys.sorted().enumerated() {
            let title = key == "context" ? "Context" : (key.isEmpty ? "Workspace root" : key)
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
                if edge.label == "import candidate" { result.append("    \(from) -.-> \(to)") }
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
