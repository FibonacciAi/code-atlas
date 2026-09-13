import Foundation

public enum ProjectIdentity {
    public static func title(_ url: URL) -> String {
        switch url.lastPathComponent {
        case "whitespace_master": return "Whitespace Master"
        case "whitespace-personal": return "Whitespace Personal · source"
        case "whitespace-context-kernel": return "Context Kernel · source"
        case "drop-chat-voice-20260908": return "Whitespace Operator · build checkout"
        default: return url.lastPathComponent
        }
    }
    public static func rejection(_ url: URL) -> String? {
        if url.pathExtension.lowercased()=="app" || url.lastPathComponent.lowercased()=="applications" {
            return "Installed apps contain compiled programs. Choose the source-code project used to build the app."
        }
        if !SourcePolicy.validateRoot(url) { return "This folder is outside the permitted folder scope." }
        return nil
    }
}
