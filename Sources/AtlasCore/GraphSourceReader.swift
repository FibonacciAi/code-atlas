import Foundation

/// Reads only small text slices from already indexed, policy-approved files.
public enum GraphSourceReader {
    public static func read(index:RepositoryIndex,fileID:Int,limit:Int=24*1024) throws -> String {
        guard index.files.indices.contains(fileID) else {throw IndexError.unreadable}
        let file=index.files[fileID], ext=URL(fileURLWithPath:file.path).pathExtension.lowercased()
        guard SourcePolicy.allowed(file.path) || ["md","markdown","txt"].contains(ext) else {throw IndexError.unreadable}
        let url=try RepoIndexer.validatedURL(root:index.root,path:file.path)
        let values=try url.resourceValues(forKeys:[.fileSizeKey])
        guard (values.fileSize ?? Int.max)<=RepoIndexer.maxFileBytes else {throw IndexError.unreadable}
        let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
        let data=try handle.read(upToCount:max(1,min(limit,24*1024))) ?? Data()
        guard !data.contains(0) else {throw IndexError.unreadable}
        return String(decoding:data,as:UTF8.self)
    }

    /// Reads the complete bounded text payload for relationship analysis.
    /// Callers should keep the returned string only for the current file.
    static func readFull(index: RepositoryIndex, fileID: Int, cancelled: () -> Bool = { false }) throws -> String {
        guard index.files.indices.contains(fileID) else { throw IndexError.unreadable }
        let file = index.files[fileID]
        let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
        guard SourcePolicy.allowed(file.path) || ["md", "markdown", "txt"].contains(ext) else { throw IndexError.unreadable }
        let url = try RepoIndexer.validatedURL(root: index.root, path: file.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= RepoIndexer.maxFileBytes else { throw IndexError.unreadable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            if cancelled() { throw CancellationError() }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > RepoIndexer.maxFileBytes { throw IndexError.unreadable }
        }
        if cancelled() { throw CancellationError() }
        guard !data.contains(0), let source = String(data: data, encoding: .utf8) else { throw IndexError.unreadable }
        return source
    }
}
