import Foundation
import Darwin

public enum LocalGit {
    public static func run(root: URL, arguments: [String], cancelled: () -> Bool = { false }, timeout: TimeInterval = 8, executable: URL = URL(fileURLWithPath:"/usr/bin/git")) throws -> Data {
        if cancelled() { throw IndexError.cancelled }
        let p=Process(); p.executableURL=executable; p.currentDirectoryURL=URL(fileURLWithPath:"/private/tmp")
        p.arguments=["--no-optional-locks","--git-dir",root.appendingPathComponent(".git").path,"--work-tree",root.path]+arguments
        let pipe=Pipe(); p.standardOutput=pipe; p.standardError=FileHandle.nullDevice
        do { try p.run() } catch { throw IndexError.gitUnavailable }
        let fd=pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
        let deadline=Date().addingTimeInterval(timeout)
        var data=Data(); var bytes=[UInt8](repeating:0,count:65536)
        while true {
            if cancelled() || Date()>deadline || data.count>32*1024*1024 {
                if p.isRunning { p.terminate() }; throw cancelled() ? IndexError.cancelled : IndexError.gitUnavailable
            }
            let n=Darwin.read(fd,&bytes,bytes.count)
            if n>0 { data.append(contentsOf:bytes.prefix(n)); continue }
            if n==0 { break }
            if errno != EAGAIN && errno != EINTR { if p.isRunning { p.terminate() }; throw IndexError.gitUnavailable }
            usleep(20_000)
        }
        while p.isRunning {
            if cancelled() || Date()>deadline { p.terminate(); throw cancelled() ? IndexError.cancelled : IndexError.gitUnavailable }
            usleep(20_000)
        }
        guard p.terminationStatus==0 else { throw IndexError.gitUnavailable }
        return data
    }

    /// The nearest enclosing repository, so opening a subfolder of a checkout
    /// still reports Git state instead of silently falling back to "unavailable".
    public static func repositoryRoot(for folder: URL, limit: Int = 12) -> URL? {
        var current=folder.resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<limit {
            if FileManager.default.fileExists(atPath:current.appendingPathComponent(".git").path) { return current }
            let parent=current.deletingLastPathComponent().standardizedFileURL
            if parent.path==current.path || current.path=="/" { return nil }
            current=parent
        }
        return nil
    }

    /// Path prefix that turns a repository-relative path into a folder-relative
    /// one. Empty when the folder is the repository root.
    public static func relativePrefix(of folder: URL, in repository: URL) -> String {
        let folderPath=folder.resolvingSymlinksInPath().standardizedFileURL.path
        let repositoryPath=repository.resolvingSymlinksInPath().standardizedFileURL.path
        guard folderPath != repositoryPath, folderPath.hasPrefix(repositoryPath+"/") else { return "" }
        return String(folderPath.dropFirst(repositoryPath.count+1))+"/"
    }
}

public struct GitChanges: Sendable {
    public let statuses: [String:String]
    public var deleted: Int { statuses.values.filter{$0.contains("D")}.count }
    public static func parse(_ data: Data, strippingPrefix prefix: String = "") -> GitChanges {
        let records=data.split(separator:0,omittingEmptySubsequences:false)
        var statuses: [String:String]=[:]; var i=0
        while i<records.count {
            let record=String(decoding:records[i],as:UTF8.self); i += 1
            guard record.utf8.count>=4 else { continue }
            let state=String(record.prefix(2)); var path=String(record.dropFirst(3))
            if state.contains("R") || state.contains("C") { i += 1 }
            if !prefix.isEmpty {
                // Paths outside the opened folder belong to the wider repository.
                guard path.hasPrefix(prefix) else { continue }
                path=String(path.dropFirst(prefix.count))
            }
            if SourcePolicy.allowed(path) { statuses[path]=state }
        }
        return GitChanges(statuses:statuses)
    }
    public static func read(_ root: URL, cancelled: () -> Bool = {false}) throws -> GitChanges {
        guard let repository=LocalGit.repositoryRoot(for:root) else { throw IndexError.gitUnavailable }
        let data=try LocalGit.run(root:repository,arguments:["status","--porcelain=v1","-z","--untracked-files=all"],cancelled:cancelled)
        return parse(data,strippingPrefix:LocalGit.relativePrefix(of:root,in:repository))
    }
}

public struct ImportLinks: Sendable {
    public let resolved: [Int]
    public let unresolved: [String]
    public static func find(source: String, file: SourceFile, files: [SourceFile]) -> ImportLinks {
        if file.language == "py" { return ImportResolver(files: files).find(source: source, file: file) }
        return generic(source: source, file: file, files: files)
    }
    fileprivate static func generic(source: String, file: SourceFile, files: [SourceFile], lookup: [String:[Int]]? = nil) -> ImportLinks {
        let patterns=[#"(?m)^\s*from\s+([.\w]+)\s+import"#,#"(?m)^\s*import\s+([\w.]+)"#,#"(?:from\s*|require\s*\(|import\s*\()\s*["']([^"']+)["']"#,#"(?m)^\s*use\s+([\w:]+)"#,#"#include\s*"([^"]+)""#]
        var modules=Set<String>()
        for pattern in patterns {
            guard let regex=try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
                if let range=Range(match.range(at:1),in:source) { modules.insert(String(source[range])) }
            }
        }
        let base=URL(fileURLWithPath:"/"+file.path).deletingLastPathComponent()
        var linked=Set<Int>(); var unresolved: [String]=[]
        for module in modules.sorted() {
            let target: String
            if module.hasPrefix("./") || module.hasPrefix("../") {
                target=base.appendingPathComponent(module).standardizedFileURL.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            } else { target=module.replacingOccurrences(of:"::",with:"/").replacingOccurrences(of:".",with:"/") }
            let matches:[Int]
            if let lookup {matches=(lookup[target] ?? []).filter {files[$0].path != file.path}}
            else {matches=files.indices.filter { id in
                let path=files[id].path, stem=(path as NSString).deletingPathExtension
                return path != file.path && (path == target || stem == target || stem.hasSuffix("/"+target) || stem == target+"/index" || stem == target+"/__init__")
            }}
            if matches.isEmpty { unresolved.append(module) } else { linked.formUnion(matches) }
        }
        return ImportLinks(resolved:linked.sorted {files[$0].path<files[$1].path},unresolved:unresolved)
    }
}

/// Indexed Python resolver. Exact keys avoid O(files²) scans and ambiguous
/// suffix matches while supporting src layouts and relative imports.
public struct ImportResolver: Sendable {
    private static let fromRegex = try! NSRegularExpression(pattern: #"^\s*from\s+([.A-Za-z_][.A-Za-z0-9_.]*)\s+import\s+(.+)$"#)
    private static let importRegex = try! NSRegularExpression(pattern: #"^\s*import\s+(.+)$"#)
    private let files: [SourceFile]
    private let exact: [String: [Int]]
    private let genericLookup: [String:[Int]]
    public init(files: [SourceFile]) {
        self.files = files
        var generic:[String:Set<Int>]=[:]
        for (id,file) in files.enumerated() {
            let stem=(file.path as NSString).deletingPathExtension
            generic[file.path,default:[]].insert(id)
            let parts=stem.split(separator:"/")
            for offset in parts.indices {generic[parts[offset...].joined(separator:"/"),default:[]].insert(id)}
            if ["index","__init__"].contains(parts.last.map(String.init) ?? "") {generic[parts.dropLast().joined(separator:"/"),default:[]].insert(id)}
        }
        genericLookup=generic.mapValues {Array($0)}
        var lookup: [String: [Int]] = [:]
        for (id, file) in files.enumerated() where file.language == "py" {
            let stem = (file.path as NSString).deletingPathExtension
            lookup[stem, default: []].append(id)
            if file.path.hasPrefix("src/") { lookup[String(stem.dropFirst(4)).replacingOccurrences(of: "/", with: "."), default: []].append(id) }
            if stem.hasSuffix("/__init__") {
                let packageStem = String(stem.dropLast("/__init__".count))
                lookup[packageStem, default: []].append(id)
                if packageStem.hasPrefix("src/") { lookup[String(packageStem.dropFirst(4)).replacingOccurrences(of: "/", with: "."), default: []].append(id) }
            }
        }
        exact = lookup.mapValues { Array(Set($0)) }
    }
    public func find(source: String, file: SourceFile) -> ImportLinks {
        guard file.language == "py" else { return ImportLinks.generic(source: source, file: file, files: files, lookup:genericLookup) }
        let clean = Self.scrub(source), lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var modules=Set<String>(), childrenByBase:[String:Set<String>]=[:], childSymbols=Set<String>()
        var i=0
        while i<lines.count {
            if let m=Self.capture(lines[i],Self.fromRegex) {
                var tail=m[1]
                while ((tail.contains("(") && !tail.contains(")")) || tail.hasSuffix("\\")) && i+1<lines.count {
                    tail=tail.trimmingCharacters(in:CharacterSet(charactersIn:"\\"));i+=1;tail+=" "+lines[i]
                }
                let base=m[0];modules.insert(base)
                for item in tail.split(separator:",") {
                    let symbol=item.trimmingCharacters(in:CharacterSet(charactersIn:"() \t\r")).split(whereSeparator:{$0.isWhitespace}).first.map(String.init) ?? ""
                    guard !symbol.isEmpty,symbol != "*" else {continue}
                    let child=base+((base.last == ".") ? "":".")+symbol
                    modules.insert(child);childSymbols.insert(child);childrenByBase[base,default:[]].insert(child)
                }
            } else if let m=Self.capture(lines[i],Self.importRegex) {
                for item in m[0].split(separator:",") {if let name=item.split(whereSeparator:{$0.isWhitespace}).first {modules.insert(String(name))}}
            }
            i+=1
        }
        let directory=(file.path as NSString).deletingLastPathComponent
        var probe=directory,depth=0
        while exact[(probe as NSString).appendingPathComponent("__init__")]?.count == 1 {
            depth+=1;probe=(probe as NSString).deletingLastPathComponent
        }
        // Namespace packages may omit __init__.py; an explicit src root still
        // establishes the maximum legal relative climb.
        if depth==0 {depth=max(0,directory.split(separator:"/").count-(directory.hasPrefix("src/") ? 1:0))}
        func matches(_ module:String)->Set<Int> {
            let keys:[String]
            if module.hasPrefix(".") {
                let dots=module.prefix {$0 == "."}.count
                guard dots<=depth else {return []}
                let parts=directory.split(separator:"/").dropLast(dots-1).map(String.init)
                let suffix=String(module.dropFirst(dots)).replacingOccurrences(of:".",with:"/")
                let path=(parts+(suffix.isEmpty ? []:[suffix])).joined(separator:"/")
                keys=[path,path+"/__init__"]
            } else {
                let path=module.replacingOccurrences(of:".",with:"/")
                keys=[module,path,path+"/__init__"]
            }
            return Set(keys.flatMap {exact[$0] ?? []})
        }
        var linked=Set<Int>(),unresolved:[String]=[]
        for module in modules.sorted() {
            let candidates=matches(module)
            if candidates.count==1,let id=candidates.first {
                if files[id].path==file.path {continue}
                if files[id].path.hasSuffix("/__init__.py"),let children=childrenByBase[module],children.contains(where:{matches($0).count==1}) {continue}
                linked.insert(id)
            } else if !childSymbols.contains(module) {unresolved.append(module)}
        }
        return ImportLinks(resolved:linked.sorted {files[$0].path<files[$1].path},unresolved:unresolved)
    }
    private static func capture(_ line: String, _ regex: NSRegularExpression) -> [String]? { guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }; return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: line).map { String(line[$0]) } } }
    private static func scrub(_ source: String) -> String {
        var out = "", i = source.startIndex, quote: Character?, triple = false, escaped = false
        while i < source.endIndex { let c = source[i]
            if let q = quote { if triple && source[i...].hasPrefix(String(repeating: q, count: 3)) { out += "   "; i = source.index(i, offsetBy: 3); quote = nil; triple = false; continue }; if !triple && c == q && !escaped { out.append(" "); i = source.index(after: i); quote = nil; continue }; out.append(c == "\n" ? "\n" : " "); escaped = c == "\\" && !escaped; if c != "\\" { escaped = false }; i = source.index(after: i); continue }
            if c == "#" { while i < source.endIndex && source[i] != "\n" { out.append(" "); i = source.index(after: i) }; continue }
            if c == "\"" || c == "'" { triple = source[i...].hasPrefix(String(repeating: c, count: 3)); quote = c; out += triple ? "   " : " "; i = source.index(i, offsetBy: triple ? 3 : 1); continue }; out.append(c); i = source.index(after: i)
        }; return out
    }
}

public enum SymbolOccurrences {
    public static func count(_ symbol: String, in source: String) -> Int {
        guard symbol.range(of:#"^[A-Za-z_][A-Za-z0-9_]{1,100}$"#,options:.regularExpression) != nil,
              let regex=try? NSRegularExpression(pattern:"\\b"+NSRegularExpression.escapedPattern(for:symbol)+"\\b") else { return 0 }
        return regex.numberOfMatches(in:source,range:NSRange(source.startIndex...,in:source))
    }
}
