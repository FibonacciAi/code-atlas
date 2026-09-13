import Foundation

public enum ProjectIdentity {
    public static func title(_ url: URL) -> String {
        url.lastPathComponent
    }
    public static func rejection(_ url: URL) -> String? {
        if url.pathExtension.lowercased()=="app" || url.lastPathComponent.lowercased()=="applications" {
            return "Installed apps contain compiled programs. Choose the source-code project used to build the app."
        }
        if !SourcePolicy.validateRoot(url) { return "This folder is outside the permitted folder scope." }
        return nil
    }
}
