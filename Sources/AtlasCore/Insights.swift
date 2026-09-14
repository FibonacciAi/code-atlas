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
            let matches=files.indices.filter { id in
                let path=files[id].path, stem=(path as NSString).deletingPathExtension
                return path != file.path && (path == target || stem == target || stem.hasSuffix("/"+target) || stem == target+"/index" || stem == target+"/__init__")
            }
            if matches.isEmpty { unresolved.append(module) } else { linked.formUnion(matches) }
        }
        return ImportLinks(resolved:linked.sorted {files[$0].path<files[$1].path},unresolved:unresolved)
    }
}

public enum SymbolOccurrences {
    public static func count(_ symbol: String, in source: String) -> Int {
        guard symbol.range(of:#"^[A-Za-z_][A-Za-z0-9_]{1,100}$"#,options:.regularExpression) != nil,
              let regex=try? NSRegularExpression(pattern:"\\b"+NSRegularExpression.escapedPattern(for:symbol)+"\\b") else { return 0 }
        return regex.numberOfMatches(in:source,range:NSRange(source.startIndex...,in:source))
    }
}
