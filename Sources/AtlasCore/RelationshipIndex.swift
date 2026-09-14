import Foundation

/// Complete, bounded relationship evidence for every eligible indexed text file.
/// Source text is read one file at a time and is never retained in the result.
public struct RelationshipIndex: Sendable {
    public let edges: [WorkspaceGraph.Edge]
    public let scannedFiles: Int
    public let eligibleFiles: Int
    public let unreadableFiles: Int
    public let excludedFiles: Int
    public let isComplete: Bool
    public let summary: String

    public static func scan(index: RepositoryIndex, cancelled: () -> Bool = { false }, progress: ((Int, Int) -> Void)? = nil) throws -> RelationshipIndex {
        let eligible = index.files.indices.filter { Self.isEligible(index.files[$0]) }
        let resolver = ImportResolver(files: index.files)
        var markdownLookup: [String: Int] = [:]
        for fileID in index.files.indices { markdownLookup[index.files[fileID].path] = fileID }
        var edges: [String: WorkspaceGraph.Edge] = [:]
        var scanned = 0
        var unreadable = 0
        var lastProgress = Date.distantPast
        func report(_ force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastProgress) >= 0.2 { progress?(scanned, eligible.count); lastProgress = now }
        }
        for fileID in index.files.indices {
            if cancelled() { throw CancellationError() }
            guard Self.isEligible(index.files[fileID]) else { continue }
            do {
                let source = try GraphSourceReader.readFull(index: index, fileID: fileID, cancelled: cancelled)
                let imports = resolver.find(source: source, file: index.files[fileID])
                for target in imports.resolved where index.files.indices.contains(target) {
                    let edge = WorkspaceGraph.Edge(from: "file:\(index.files[fileID].path)", to: "file:\(index.files[target].path)", label: "import candidate")
                    edges["\(edge.from)\u{1f}\(edge.to)\u{1f}\(edge.label)"] = edge
                }
                for target in markdownRelationshipTargets(source: source, file: index.files[fileID], lookup: markdownLookup) {
                    let edge = WorkspaceGraph.Edge(from: "file:\(index.files[fileID].path)", to: "file:\(index.files[target].path)", label: "links")
                    edges["\(edge.from)\u{1f}\(edge.to)\u{1f}\(edge.label)"] = edge
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable += 1
            }
            scanned += 1
            report()
        }
        report(true)
        let excluded = index.files.count - eligible.count
        let sorted = edges.values.sorted { ($0.from, $0.to, $0.label) < ($1.from, $1.to, $1.label) }
        let complete = scanned == eligible.count && unreadable == 0
        let summary = "relationship scan \(scanned)/\(eligible.count) eligible files · \(sorted.count) edges · \(unreadable) unreadable · \(excluded) policy-excluded/non-text files"
        return RelationshipIndex(edges: sorted, scannedFiles: scanned, eligibleFiles: eligible.count, unreadableFiles: unreadable, excludedFiles: excluded, isComplete: complete, summary: summary)
    }

    private init(edges: [WorkspaceGraph.Edge], scannedFiles: Int, eligibleFiles: Int, unreadableFiles: Int, excludedFiles: Int, isComplete: Bool, summary: String) {
        self.edges = edges; self.scannedFiles = scannedFiles; self.eligibleFiles = eligibleFiles; self.unreadableFiles = unreadableFiles; self.excludedFiles = excludedFiles; self.isComplete = isComplete; self.summary = summary
    }

    private static func isEligible(_ file: SourceFile) -> Bool {
        let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
        return SourcePolicy.allowed(file.path) || ["md", "markdown", "txt"].contains(ext)
    }
}

private func markdownRelationshipTargets(source: String, file: SourceFile, lookup: [String: Int]) -> [Int] {
    guard let regex = try? NSRegularExpression(pattern: #"!?(?:\[[^\]]*\])\(([^)\s]+)"#) else { return [] }
    return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: source) else { return nil }
        var reference = String(source[range]).removingPercentEncoding ?? String(source[range])
        if let hash = reference.firstIndex(of: "#") { reference = String(reference[..<hash]) }
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.contains("://"), !reference.lowercased().hasPrefix("mailto:") else { return nil }
        var components = file.path.split(separator: "/").dropLast().map(String.init)
        for component in reference.split(separator: "/").map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." { guard !components.isEmpty else { return nil }; components.removeLast() } else { components.append(component) }
        }
        return lookup[components.joined(separator: "/")]
    }
}
