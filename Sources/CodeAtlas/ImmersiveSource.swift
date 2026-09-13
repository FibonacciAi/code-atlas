import AppKit
import AtlasCore

/// A file occupies the map's viewport; the map camera stays underneath it.
final class ImmersiveSource: NSView {
    var onExit:(()->Void)?
    let text=NSTextView()
    let scroll=NSScrollView()
    private let heading=NSTextField(labelWithString:"")
    private let hint=NSTextField(labelWithString:"Scroll to read · Keep scrolling up at the top to return · Esc")
    override var isFlipped:Bool {true}
    init(path:String) {
        super.init(frame:.zero)
        wantsLayer=true; layer?.backgroundColor=NSColor(calibratedRed:0.04,green:0.065,blue:0.09,alpha:1).cgColor; layer?.cornerRadius=10; layer?.masksToBounds=true
        heading.stringValue=path; heading.font = .systemFont(ofSize:13,weight:.semibold); heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let back=NSButton(title:"← Map  ·  Esc",target:self,action:#selector(exitReader)); back.bezelStyle = .rounded
        let bar=NSStackView(views:[back,heading]); bar.spacing=14; bar.detachesHiddenViews=false; bar.translatesAutoresizingMaskIntoConstraints=false; addSubview(bar)
        scroll.translatesAutoresizingMaskIntoConstraints=false; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=false; scroll.drawsBackground=false; scroll.verticalScrollElasticity = .none
        text.isEditable=false; text.isSelectable=true; text.isRichText=false; text.drawsBackground=false; text.isVerticallyResizable=true; text.autoresizingMask=[.width]; text.textContainer?.widthTracksTextView=true; text.textContainerInset=NSSize(width:22,height:18)
        text.minSize=NSSize(width:0,height:0); text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude); text.isHorizontallyResizable=false
        text.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        text.font = .monospacedSystemFont(ofSize:13,weight:.regular); text.textColor = .labelColor; text.string="Opening source…"
        scroll.documentView=text; addSubview(scroll)
        hint.font = .systemFont(ofSize:10); hint.textColor = .secondaryLabelColor; hint.translatesAutoresizingMaskIntoConstraints=false; addSubview(hint)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),bar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),bar.topAnchor.constraint(equalTo:topAnchor,constant:12),bar.heightAnchor.constraint(equalToConstant:30),scroll.topAnchor.constraint(equalTo:bar.bottomAnchor,constant:10),scroll.leadingAnchor.constraint(equalTo:leadingAnchor),scroll.trailingAnchor.constraint(equalTo:trailingAnchor),scroll.bottomAnchor.constraint(equalTo:hint.topAnchor,constant:-8),hint.leadingAnchor.constraint(equalTo:leadingAnchor,constant:22),hint.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-12)])
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layout() {
        super.layout()
        let size=scroll.contentSize
        guard size.width>0 else {return}
        text.minSize=NSSize(width:0,height:size.height)
        if abs(text.frame.width-size.width)>0.5 {
            text.setFrameSize(NSSize(width:size.width,height:max(text.frame.height,size.height)))
        }
    }
    @objc private func exitReader() {onExit?()}
    override func cancelOperation(_ sender:Any?) {onExit?()}
    func setPullProgress(_ progress:Double) {
        hint.stringValue=progress>0 ? "↑ Keep scrolling up to return to the map" : "Scroll to read · Keep scrolling up at the top to return · Esc"
        hint.textColor=progress>0 ? .controlAccentColor : .secondaryLabelColor
    }
    func show(_ content:String) {
        layoutSubtreeIfNeeded()
        // Keep the entire bounded source readable; style only its first 128 KiB.
        let styled=NSMutableAttributedString(string:content,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor])
        let prefix=String(content.prefix(128_000)), first=SourceStyle.highlight(prefix)
        styled.replaceCharacters(in:NSRange(location:0,length:(prefix as NSString).length),with:first)
        text.textStorage?.setAttributedString(styled)
        text.scrollToBeginningOfDocument(nil)
    }
}
