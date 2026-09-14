import Foundation

public struct OutlineEntry: Sendable, Equatable {
    public let line: Int
    public let title: String
    public init(line: Int, title: String) { self.line = line; self.title = title }
}

/// Lexical declaration outline. This matches text, it does not parse: entries are
/// candidates, not resolved definitions.
public enum OutlineIndex {
    private static let modifiers = "(?:public|private|internal|fileprivate|open|static|final|export|async|pub|mut|unsafe|override|abstract|sealed|inline|readonly|partial|virtual|extern|suspend|declare|default)"
    private static let declarations = "(?:func|fn|def|class|struct|enum|protocol|interface|function|trait|actor|extension|impl|typealias|type|namespace|module|record|object|union|macro)"

    private static let declaration = try! NSRegularExpression(
        pattern: "^\\s*(?:\(modifiers)\\s+)*\(declarations)\\s+[A-Za-z_][A-Za-z0-9_]*"
    )
    // const handler = (…) =>, export const view = function…, let make = async (…
    private static let boundFunction = try! NSRegularExpression(
        pattern: "^\\s*(?:export\\s+)?(?:const|let|var)\\s+[A-Za-z_$][A-Za-z0-9_$]*\\s*(?::[^=]{1,80})?=\\s*(?:async\\s*)?(?:function\\b|\\([^)]{0,120}\\)\\s*(?::[^=]{1,60})?=>|[A-Za-z_$][A-Za-z0-9_$]*\\s*=>)"
    )

    public static func entries(_ content: String, limit: Int = 200) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        for (line, slice) in content.components(separatedBy: "\n").enumerated() {
            let range = NSRange(slice.startIndex..., in: slice)
            guard declaration.firstMatch(in: slice, range: range) != nil
                    || boundFunction.firstMatch(in: slice, range: range) != nil else { continue }
            entries.append(OutlineEntry(line: line, title: String(slice.trimmingCharacters(in: .whitespaces).prefix(90))))
            if entries.count >= limit { break }
        }
        return entries
    }
}
