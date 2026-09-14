import Foundation

/// A restorable window preference snapshot. This deliberately contains paths
/// and controls only; it must never contain indexed source or connected data.
struct SavedWorkspaceView: Codable, Equatable {
    let rootPath: String?
    let viewMode: Int
    let searchText: String
    let kindFilter: Int
    let changesOnly: Bool
    let sizing: Int
    let colorMode: Int
    let selectedFilePath: String?
    var graphScope: Int? = nil

    static func capture(rootPath: String?, viewMode: Int, searchText: String,
                        kindFilter: Int, changesOnly: Bool, sizing: Int,
                        colorMode: Int, selectedFilePath: String?) -> Self {
        Self(rootPath: rootPath, viewMode: viewMode, searchText: searchText,
             kindFilter: kindFilter, changesOnly: changesOnly, sizing: sizing,
             colorMode: colorMode, selectedFilePath: selectedFilePath)
    }
}

enum SavedWorkspaceViewStore {
    private static let key = "savedWorkspaceView"

    static func save(_ view: SavedWorkspaceView, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(view) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(from defaults: UserDefaults) -> SavedWorkspaceView? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedWorkspaceView.self, from: data)
    }
}
