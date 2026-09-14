import AppKit
import AtlasCore

/// AppKit presentation for `SyntaxSpans`. The scan itself is pure and runs off
/// the main thread; only the attributed string is built here.
enum SourceStyle {
    static func spans(_ text: String, language: String = "") -> [SyntaxSpans.Span] {
        SyntaxSpans.scan(text, language: language)
    }

    static func attributed(_ text: String, spans: [SyntaxSpans.Span]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.8, green: 0.87, blue: 0.9, alpha: 1)
        ])
        let length = result.length
        for span in spans {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location + span.range.length <= length else { continue }
            let color: NSColor
            switch span.kind {
            case .comment: color = .secondaryLabelColor
            case .string: color = .systemGreen
            case .number: color = .systemOrange
            case .keyword: color = .systemPurple
            }
            result.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        return result
    }

    static func highlight(_ text: String, language: String = "") -> NSAttributedString {
        attributed(text, spans: spans(text, language: language))
    }
}
