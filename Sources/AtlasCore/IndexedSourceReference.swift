import Foundation

/// Connects evidence back to an existing file tile without expanding file access.
public enum IndexedSourceReference {
    public static func fileID(_ reference:String,in index:RepositoryIndex)->Int? {
        guard !reference.isEmpty,!reference.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {return nil}
        let path:String
        if let components=URLComponents(string:reference),components.scheme != nil {
            guard components.scheme?.lowercased()=="file",
                  components.host == nil || components.host == "" || components.host?.lowercased()=="localhost",
                  components.user == nil,components.password == nil,components.port == nil,
                  components.query == nil,components.fragment == nil,components.path.hasPrefix("/") else {return nil}
            path=components.path
        } else {path=reference}
        // Reject traversal before URL normalization can erase it.
        guard !path.split(separator:"/").contains(where:{$0==".." || $0=="."}) else {return nil}
        let relative:String
        if path.hasPrefix("/") {
            let root=index.root.standardizedFileURL.path+"/"
            let normalized=URL(fileURLWithPath:path).standardizedFileURL.path
            guard normalized.hasPrefix(root) else {return nil}
            relative=String(normalized.dropFirst(root.count))
        } else {relative=path}
        guard SourcePolicy.allowedContent(relative) else {return nil}
        return index.files.firstIndex {$0.path==relative}
    }
}
