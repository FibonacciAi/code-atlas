import AppKit

enum SourceStyle {
    static func highlight(_ text:String) -> NSAttributedString {
        let result=NSMutableAttributedString(string:text,attributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor(calibratedRed:0.8,green:0.87,blue:0.9,alpha:1)])
        let patterns:[(String,NSColor)]=[
            (#"\b(import|from|class|struct|enum|func|fn|def|let|var|const|return|if|else|for|while|try|catch|throw|async|await|public|private|static|self|None|True|False|nil|true|false|export|function|use|pub)\b"#,.systemPurple),
            (#"\b[0-9]+(?:\.[0-9]+)?\b"#,.systemOrange),
            (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,.systemGreen),
            (#"(?m)(?://|#)[^\n]*"#,.secondaryLabelColor)
        ]
        for (pattern,color) in patterns {
            guard let regex=try? NSRegularExpression(pattern:pattern) else {continue}
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) { result.addAttribute(.foregroundColor,value:color,range:match.range) }
        }
        return result
    }
}
