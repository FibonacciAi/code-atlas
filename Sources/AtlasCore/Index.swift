import Foundation
import Darwin

public enum ContentKind: String, Sendable {
    case code, html, image, video, audio, pdf, document
    public static func classify(extension ext:String) -> ContentKind {
        let ext=ext.lowercased()
        if ["html","htm"].contains(ext) {return .html}
        if ["png","jpg","jpeg","heic","heif","gif","webp","tif","tiff","bmp","avif"].contains(ext) {return .image}
        if ["mov","mp4","m4v","webm","mkv","avi"].contains(ext) {return .video}
        if ["mp3","m4a","wav","aiff","aif","flac","ogg","aac"].contains(ext) {return .audio}
        if ext=="pdf" {return .pdf}
        if ["txt","md","markdown","rtf","doc","docx","odt","pages","ppt","pptx","key","xls","xlsx","numbers"].contains(ext) {return .document}
        return .code
    }
}

public struct SourceFile: Sendable {
    public let path: String
    public let lines: Int
    public let bytes: Int
    public var kind: ContentKind { ContentKind.classify(extension:language) }
    public var language: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    public init(path: String, lines: Int, bytes: Int) { self.path = path; self.lines = lines; self.bytes = bytes }
}

public struct RepositoryIndex: Sendable {
    public let root: URL
    public let files: [SourceFile]
    public let skipped: Int
    public let limited: Bool
    public let seconds: Double
    public let usesGitIgnore: Bool
    public var lines: Int { files.reduce(0) { $0 + $1.lines } }
    public init(root: URL, files: [SourceFile], skipped: Int = 0, limited: Bool = false, seconds: Double = 0, usesGitIgnore: Bool = false) {
        self.root = root; self.files = files; self.skipped = skipped; self.limited = limited; self.seconds = seconds; self.usesGitIgnore = usesGitIgnore
    }
}

public enum IndexError: LocalizedError {
    case unsafeRoot, unreadable, cancelled, gitUnavailable
    public var errorDescription: String? {
        switch self {
        case .unsafeRoot: return "Choose a source project outside private graph, state, or credential folders."
        case .unreadable: return "This folder could not be read. Choose another project."
        case .cancelled: return "Indexing cancelled."
        case .gitUnavailable: return "Git file discovery timed out or failed. Choose the folder again with Open Project, then retry."
        }
    }
}

public enum SourcePolicy {
    public static let extensions: Set<String> = ["swift","rs","py","js","jsx","ts","tsx","mjs","cjs","c","cc","cpp","cxx","h","hpp","m","mm","metal","glsl","wgsl","go","java","kt","kts","cs","rb","php","html","htm","css","scss","sass","vue","svelte","sh","bash","zsh","sql","proto","ex","exs","clj","scala","dart","lua","r","jl"]
    public static let excluded: Set<String> = [".git",".ssh",".aws",".config",".codex",".claude",".agents","node_modules","target","build","dist","output","outputs","tmp","temp","venv","env",".venv","__pycache__",".build","deriveddata","vendor","pods","carthage","coverage",".next",".cache","graph","state","secrets","credentials","keychains","fixtures","backups"]
    public static func safeComponents(_ components: [String]) -> Bool {
        !components.contains { item in
            let name = item.lowercased()
            return excluded.contains(name) || name.hasPrefix(".") || name.contains("dork") || name.contains("credential") || name.contains("secret") || name.hasSuffix(".app")
        }
    }
    public static func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return !path.hasPrefix("/") && !parts.contains("..") && safeComponents(parts) && extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    public static func allowedContent(_ path:String) -> Bool {
        let parts=path.split(separator:"/").map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), safeComponents(parts) else {return false}
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        return extensions.contains(ext) || ContentKind.classify(extension:ext) != .code
    }
    public static func validateRoot(_ root: URL) -> Bool {
        // Resolve root aliases, but never traverse child symlinks.
        let components = root.resolvingSymlinksInPath().pathComponents.dropFirst()
        let privateRoots: Set<String> = [".ssh",".aws",".config",".codex",".claude",".agents","graph","state","secrets","credentials","keychains","backups"]
        return !components.contains {
            let name=$0.lowercased()
            return name.hasPrefix(".") || privateRoots.contains(name) || name.hasSuffix(" backups") || name.hasSuffix(" legacy") || name.contains("credential") || name.contains("secret") || name.contains("dork") || name.hasSuffix(".app")
        }
    }
}

public enum RepoIndexer {
    public static let maxFileBytes = 4 * 1024 * 1024
    public static let maxFiles = 50_000
    /// Revalidate on each preview/open; never follow symlinks inside a chosen folder.
    public static func validatedURL(root:URL,path:String) throws -> URL {
        guard SourcePolicy.validateRoot(root), SourcePolicy.allowedContent(path) else {throw IndexError.unsafeRoot}
        var current=root.resolvingSymlinksInPath()
        for part in path.split(separator:"/") {
            current.appendPathComponent(String(part))
            let values=try current.resourceValues(forKeys:[.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {throw IndexError.unsafeRoot}
        }
        guard try current.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {throw IndexError.unreadable}
        return current
    }
    public static func readSource(root: URL, path: String, limit: Int = maxFileBytes) throws -> Data {
        guard SourcePolicy.validateRoot(root), SourcePolicy.allowed(path) else { throw IndexError.unsafeRoot }
        let current = try validatedURL(root:root,path:path)
        let values = try current.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maxFileBytes else { throw IndexError.unreadable }
        let handle = try FileHandle(forReadingFrom: current)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: min(limit, maxFileBytes) + 1) ?? Data()
        guard !data.contains(0) else { throw IndexError.unreadable }
        return data
    }
    /// Counts newlines over the raw buffer. `Data.reduce` dominated scan time on
    /// large folders because every byte went through Data's element subscript.
    static func countLines(_ data: Data) -> Int {
        let newlines = data.withUnsafeBytes { buffer -> Int in
            var total = 0
            for byte in buffer where byte == 10 { total += 1 }
            return total
        }
        return newlines + (data.last == 10 ? 0 : 1)
    }
    public static func scan(_ input: URL, includeMedia:Bool = false, cancelled: () -> Bool = { false }) throws -> RepositoryIndex {
        let start = Date()
        let root = input.resolvingSymlinksInPath().standardizedFileURL
        guard SourcePolicy.validateRoot(root) else { throw IndexError.unsafeRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw IndexError.unreadable }
        var files: [SourceFile] = []; var skipped = 0; var limited = false
        let gitPaths = try gitFiles(root, cancelled: cancelled)
        func accept(_ path: String) throws {
            if cancelled() { throw IndexError.cancelled }
            guard files.count < maxFiles else { limited = true; return }
            guard includeMedia ? SourcePolicy.allowedContent(path) : SourcePolicy.allowed(path) else { skipped += 1; return }
            if !SourcePolicy.allowed(path) {
                // Media and documents are indexed from metadata, never decoded or loaded here.
                guard let url=try? validatedURL(root:root,path:path),
                      let values=try? url.resourceValues(forKeys:[.fileSizeKey]),
                      let bytes=values.fileSize else {skipped += 1;return}
                files.append(SourceFile(path:path,lines:0,bytes:bytes)); return
            }
            guard let data = try? readSource(root: root, path: path), data.count <= maxFileBytes, String(data: data, encoding: .utf8) != nil else { skipped += 1; return }
            let lines = data.isEmpty ? 0 : countLines(data)
            files.append(SourceFile(path: path, lines: lines, bytes: data.count))
        }
        if let paths = gitPaths {
            for path in paths { try accept(path); if limited { break } }
        } else {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in skipped += 1; return true }) else { throw IndexError.unreadable }
            for case let url as URL in enumerator {
                if cancelled() { throw IndexError.cancelled }
                // Foundation enumeration can return /private/var while the root
                // standardizes to /var. Normalize both before deriving a path.
                let normalized = url.standardizedFileURL.path
                guard normalized.hasPrefix(root.path + "/") else { enumerator.skipDescendants(); skipped += 1; continue }
                let relative = String(normalized.dropFirst(root.path.count + 1))
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                if values?.isSymbolicLink == true || !SourcePolicy.safeComponents(relative.split(separator: "/").map(String.init)) {
                    enumerator.skipDescendants(); skipped += 1; continue
                }
                if values?.isDirectory == true { continue }
                try accept(relative); if limited { break }
            }
        }
        return RepositoryIndex(root: root, files: files.sorted { $0.path < $1.path }, skipped: skipped, limited: limited, seconds: Date().timeIntervalSince(start), usesGitIgnore: gitPaths != nil)
    }
    static func gitFiles(_ root: URL, cancelled: () -> Bool, executable: URL = URL(fileURLWithPath:"/usr/bin/git"), timeout: TimeInterval = 8) throws -> [String]? {
        // A subfolder of a checkout is still inside the repository: ask the nearest
        // enclosing one and keep only the paths under the folder that was opened.
        guard let repository=LocalGit.repositoryRoot(for:root) else { return nil }
        let data=try LocalGit.run(root:repository,arguments:["ls-files","-z","--cached","--others","--exclude-standard"],cancelled:cancelled,timeout:timeout,executable:executable)
        let prefix=LocalGit.relativePrefix(of:root,in:repository)
        var paths=Set<String>()
        for slice in data.split(separator:0) {
            guard let path=String(data:slice,encoding:.utf8), !path.isEmpty else { continue }
            if prefix.isEmpty { paths.insert(path) }
            else if path.hasPrefix(prefix) { paths.insert(String(path.dropFirst(prefix.count))) }
        }
        return paths.sorted()
    }
}
