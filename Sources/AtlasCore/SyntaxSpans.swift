import Foundation

/// Single-pass lexical scanner shared by the reader and the map preview.
///
/// Pure Foundation, so it is safe to run off the main thread. Scanning once
/// (instead of running independent regular expressions for strings and
/// comments) keeps a comment from overwriting a string that contains "//", and
/// a "#" or "--" inside a string from being mistaken for a comment.
public enum SyntaxSpans {
    public enum Kind: Sendable { case comment, string, number, keyword }
    public struct Span: Sendable, Equatable {
        public let range: NSRange
        public let kind: Kind
        public init(range: NSRange, kind: Kind) { self.range = range; self.kind = kind }
    }

    private static let keywords: Set<String> = [
        "import","from","class","struct","enum","func","fn","def","let","var","const","return","if","else",
        "for","while","try","catch","throw","throws","rethrows","async","await","public","private","internal",
        "fileprivate","open","static","final","self","None","True","False","nil","true","false","export",
        "function","use","pub","extension","impl","trait","actor","protocol","interface","type","typealias",
        "namespace","module","mod","crate","package","using","guard","defer","where","in","of","new","this",
        "super","switch","case","default","break","continue","do","match","yield","lazy","mut","unsafe",
        "override","abstract","sealed","inline","readonly","partial","virtual","extern","suspend","macro"
    ]

    private static func lineCommentTokens(for language: String) -> [[unichar]] {
        switch language {
        case "py","rb","sh","bash","zsh","r","jl","ex","exs","pl","yaml","yml","toml","tf","cfg","conf","mk":
            return [chars("#")]
        case "sql","lua","hs","elm":
            return [chars("--")]
        case "clj":
            return [chars(";")]
        case "php":
            return [chars("//"), chars("#")]
        case "css","html","htm":
            return []
        default:
            return [chars("//")]
        }
    }

    private static func blockCommentTokens(for language: String) -> ([unichar],[unichar])? {
        switch language {
        case "py","rb","sh","bash","zsh","yaml","yml","toml","clj","jl","r":
            return nil
        case "html","htm","vue","svelte":
            return (chars("<!--"), chars("-->"))
        case "lua":
            return (chars("--[["), chars("]]"))
        default:
            return (chars("/*"), chars("*/"))
        }
    }

    private static func chars(_ value: String) -> [unichar] { Array(value.utf16) }

    public static func scan(_ text: String, language: String = "") -> [Span] {
        let source = Array(text.utf16)
        let count = source.count
        guard count > 0 else { return [] }
        let language = language.lowercased()
        let lineTokens = lineCommentTokens(for: language)
        let block = blockCommentTokens(for: language)
        var spans: [Span] = []
        spans.reserveCapacity(count / 24)

        func matches(_ token: [unichar], at index: Int) -> Bool {
            guard index + token.count <= count else { return false }
            for offset in 0..<token.count where source[index + offset] != token[offset] { return false }
            return true
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isIdentStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }

        var i = 0
        while i < count {
            let c = source[i]
            if let block, matches(block.0, at: i) {
                let start = i
                i += block.0.count
                while i < count && !matches(block.1, at: i) { i += 1 }
                if i < count { i += block.1.count }
                spans.append(Span(range: NSRange(location: start, length: min(i, count) - start), kind: .comment))
                continue
            }
            if lineTokens.contains(where: { matches($0, at: i) }) {
                let start = i
                while i < count && source[i] != 10 { i += 1 }
                spans.append(Span(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            if c == 34 || c == 39 || c == 96 {
                let start = i
                i += 1
                while i < count {
                    let d = source[i]
                    if d == 92 { i += 2; continue }
                    if d == c { i += 1; break }
                    // An unterminated quote must not swallow the rest of the file.
                    if d == 10 && c != 96 { break }
                    i += 1
                }
                spans.append(Span(range: NSRange(location: start, length: min(i, count) - start), kind: .string))
                continue
            }
            if isDigit(c) {
                let start = i
                while i < count, isDigit(source[i]) || source[i] == 46 || source[i] == 95 { i += 1 }
                spans.append(Span(range: NSRange(location: start, length: i - start), kind: .number))
                continue
            }
            if isIdentStart(c) {
                let start = i
                while i < count, isIdent(source[i]) { i += 1 }
                let word = String(decoding: source[start..<i], as: UTF16.self)
                if keywords.contains(word) {
                    spans.append(Span(range: NSRange(location: start, length: i - start), kind: .keyword))
                }
                continue
            }
            i += 1
        }
        return spans
    }
}
