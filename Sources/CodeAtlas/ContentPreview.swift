import AppKit
import AtlasCore
import AVKit
import PDFKit
import WebKit
import ImageIO

enum PreviewScrollPosition {
    case canvas
    case document(atTop:Bool)
}

/// Local content stays in its native preview; opening another app is an explicit action.
final class ContentPreview: NSView, WKNavigationDelegate {
    var onClose:(()->Void)?
    private let url:URL
    private let body=NSView()
    private let note=NSTextField(labelWithString:"")
    private let staticNotice=NSTextField(wrappingLabelWithString:"")
    private weak var nativeScroll:NSScrollView?
    private weak var sourceText:NSTextView?
    private weak var pdfView:PDFView?
    private var positionPDFAtStart=false
    private var webPoll:Timer?
    private var webPollPending=false
    private var webTopSamples=0
    private var webSampleTime=Date.distantPast
    private var stopped=false
    private var webPointer:CGPoint?
    private var webScrollGeneration=0
    func prepareForScroll(_ event:NSEvent) {
        guard let web,web.superview != nil,htmlMode?.selectedSegment == 0 else {return}
        let native=web.convert(event.locationInWindow,from:nil)
        let point=CGPoint(x:native.x,y:web.isFlipped ? native.y : web.bounds.height-native.y)
        let moved=webPointer.map {hypot($0.x-point.x,$0.y-point.y)>8} ?? true
        if event.scrollingDeltaY<0 || moved {
            webTopSamples=0; webSampleTime = .distantPast; webScrollGeneration += 1
        }
        webPointer=point
        // Sampling before a downward event is dispatched could observe the previous
        // top position; defer to the next turn of the main run loop.
        DispatchQueue.main.async { [weak self] in self?.pollWebPosition() }
    }
    var preferredResponder:NSResponder {
        if let audioPreview {return audioPreview.preferredResponder}
        if let sourceText {return sourceText}
        if let web,web.superview != nil {return web}
        if let pdfView {return pdfView}
        return self
    }
    var scrollPosition:PreviewScrollPosition {
        if let scroll=nativeScroll {return .document(atTop:isAtTop(scroll))}
        if let pdf=pdfView {
            guard let scroll=findScroll(in:pdf) else {return .document(atTop:false)}
            return .document(atTop:isAtTop(scroll))
        }
        if let web,web.superview != nil {
            return .document(atTop:webTopSamples>=2 && Date().timeIntervalSince(webSampleTime)<0.35)
        }
        return .canvas
    }
    func stopPreview() {
        stopped=true; audioPreview?.stop(); player?.pause(); playerStatus=nil
        webPoll?.invalidate(); webPoll=nil; web?.stopLoading()
    }
    func didPresent() {
        guard positionPDFAtStart,let pdf=pdfView,let document=pdf.document else {return}
        positionPDFAtStart=false
        if document.pageCount == 1,let page=document.page(at:0) {
            let rect=page.bounds(for:pdf.displayBox)
            pdf.autoScales=false
            pdf.scaleFactor=min((pdf.bounds.width-24)/max(1,rect.width),(pdf.bounds.height-24)/max(1,rect.height))
        }
        pdf.layoutDocumentView();pdf.goToFirstPage(nil)
        DispatchQueue.main.async { [weak self,weak pdf] in
            guard let self,!self.stopped,let pdf,let scroll=self.findScroll(in:pdf),let view=scroll.documentView else {return}
            let top=view.isFlipped ? view.bounds.minY : max(view.bounds.minY,view.bounds.maxY-scroll.contentView.bounds.height)
            scroll.contentView.scroll(to:NSPoint(x:scroll.contentView.bounds.minX,y:top));scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func findScroll(in view:NSView)->NSScrollView? {
        if let scroll=view as? NSScrollView {return scroll}
        for child in view.subviews {if let scroll=findScroll(in:child) {return scroll}}
        return nil
    }
    private func isAtTop(_ scroll:NSScrollView)->Bool {
        guard let document=scroll.documentView else {return false}
        return document.isFlipped ? scroll.contentView.bounds.minY<=1 : document.bounds.maxY-scroll.contentView.bounds.maxY<=1
    }
    private var audioPreview:AudioPreview?
    private var player:AVPlayer?
    private var playerStatus:NSKeyValueObservation?
    private var web:WKWebView?
    private var htmlSource:String?
    private var htmlMode:NSSegmentedControl?
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}

    init(url:URL,kind:ContentKind) {
        self.url=url
        super.init(frame:.zero)
        wantsLayer=true
        layer?.backgroundColor=NSColor(calibratedRed:0.04,green:0.065,blue:0.09,alpha:1).cgColor
        body.wantsLayer=true; body.layer?.masksToBounds=true
        layer?.cornerRadius=12; layer?.masksToBounds=true
        let close=NSButton(title:"← Map · Esc",target:self,action:#selector(closePreview))
        let title=NSTextField(labelWithString:url.lastPathComponent)
        title.font = .systemFont(ofSize:14,weight:.semibold); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let open=NSButton(title:"Open in Default App",target:self,action:#selector(openDefault))
        let spacer=NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        var controls:[NSView]=[close,title,spacer]
        if kind == .html {
            let mode=NSSegmentedControl(labels:["Preview","Source"],trackingMode:.selectOne,target:self,action:#selector(changeHTMLMode))
            mode.selectedSegment=0; htmlMode=mode; controls.append(mode)
        }
        controls.append(open)
        let bar=NSStackView(views:controls); bar.spacing=12; bar.detachesHiddenViews=false
        [bar,body,note,staticNotice].forEach { $0.translatesAutoresizingMaskIntoConstraints=false; addSubview($0) }
        note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor; note.lineBreakMode = .byTruncatingTail
        staticNotice.font = .systemFont(ofSize:12,weight:.medium)
        staticNotice.textColor = .secondaryLabelColor
        staticNotice.stringValue = kind == .html ? "Static preview — scripts are off, so interactive charts and buttons may not work. Use Source to read the file." : ""
        staticNotice.isHidden = kind != .html
        NSLayoutConstraint.activate([
            staticNotice.topAnchor.constraint(equalTo:bar.bottomAnchor,constant:kind == .html ? 8 : 0),
            staticNotice.leadingAnchor.constraint(equalTo:leadingAnchor,constant:18),staticNotice.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),
            staticNotice.heightAnchor.constraint(equalToConstant:kind == .html ? 36 : 0),
            bar.topAnchor.constraint(equalTo:topAnchor,constant:12),bar.leadingAnchor.constraint(equalTo:leadingAnchor,constant:14),bar.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-14),bar.heightAnchor.constraint(equalToConstant:32),
            body.topAnchor.constraint(equalTo:staticNotice.bottomAnchor,constant:12),body.leadingAnchor.constraint(equalTo:leadingAnchor),body.trailingAnchor.constraint(equalTo:trailingAnchor),body.bottomAnchor.constraint(equalTo:note.topAnchor,constant:-10),
            note.leadingAnchor.constraint(equalTo:leadingAnchor,constant:18),note.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),note.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-12)
        ])
        guard url.isFileURL, (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true else {
            message("This file is no longer available."); return
        }
        switch kind {
        case .image:
            note.stringValue="Image preview · Scaled to fit"
            let image=NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
            if let source=CGImageSourceCreateWithURL(url as CFURL,nil), let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2560,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) {
                image.image=NSImage(cgImage:thumbnail,size:.zero); mount(image)
            } else {message("This image could not be previewed. Open it in its default app.")}
        case .audio:
            note.stringValue="Local audio · Playback volume is shown above · No automatic playback"
            let view=AudioPreview(url:url); audioPreview=view; mount(view)
        case .video:
            note.stringValue="Local media · Press Play to begin"
            let view=AVPlayerView(); view.controlsStyle = .floating
            let playback=AVPlayer(url:url); playback.volume=1; playback.isMuted=false; player=playback; view.player=playback; mount(view)
            playerStatus=playback.currentItem?.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
                guard item.status == .failed else {return}
                DispatchQueue.main.async { [weak self] in
                    self?.player?.pause()
                    self?.message("This media could not be played here. Open it in its default app.")
                }
            }
        case .pdf:
            note.stringValue="PDF · Scroll to read"
            let view=PDFView(); view.autoScales=true; view.displayMode = .singlePageContinuous
            if let document=PDFDocument(url:url) {
                if document.isLocked {message("This PDF is locked. Open it in its default app to unlock it.")}
                else if document.pageCount == 0 {message("This PDF has no readable pages. Open it in its default app.")}
                else {view.document=document; mount(view); pdfView=view;positionPDFAtStart=true}
            }
            else {message("This PDF could not be previewed. Open it in its default app.")}
        case .html:
            note.stringValue="Static HTML · Scripts and external assets disabled · Use Source if the page needs them"
            if let source=readText() {htmlSource=source; showHTML(source)}
            else {message("HTML preview supports UTF-8 files up to 4 MB. Open this file in its default app.")}
        case .code:
            note.stringValue="Read-only source"
            if let source=readText() {showText(source)} else {message("This text file could not be read within the 4 MB preview limit.")}
        case .document:
            let ext=url.pathExtension.lowercased()
            if ["md","markdown","mdown","txt","text","log","csv","tsv","rst"].contains(ext) {
                let markdown=["md","markdown","mdown"].contains(ext)
                note.stringValue=markdown ? "Markdown · Read-only · Full file with formatting marks preserved" : "Text document · Read-only"
                if let source=readText() {showText(source,markdown:markdown)}
                else {message("This document could not be read as UTF-8 within the 4 MB preview limit. Open it in its default app.")}
            } else {
                note.stringValue="Document · Open with its associated app"
                message("This document’s layout is available in its default app.\nUse Open in Default App above.")
            }
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {webPoll?.invalidate(); audioPreview?.stop(); player?.pause()}
    override func cancelOperation(_ sender:Any?) {closePreview()}
    @objc private func closePreview() {stopPreview(); onClose?()}
    @objc private func openDefault() {NSWorkspace.shared.open(url)}
    @objc private func changeHTMLMode() {
        guard let source=htmlSource else {return}
        if htmlMode?.selectedSegment == 1 {web?.stopLoading(); showText(source)} else {showHTML(source)}
    }
    private func mount(_ view:NSView) {
        nativeScroll=nil; sourceText=nil; pdfView=nil
        body.subviews.forEach {$0.removeFromSuperview()}
        view.translatesAutoresizingMaskIntoConstraints=false; body.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:body.leadingAnchor),view.trailingAnchor.constraint(equalTo:body.trailingAnchor),view.topAnchor.constraint(equalTo:body.topAnchor),view.bottomAnchor.constraint(equalTo:body.bottomAnchor)])
    }
    private func message(_ text:String) {
        webPoll?.invalidate(); webPoll=nil
        nativeScroll=nil; sourceText=nil; pdfView=nil
        let label=NSTextField(wrappingLabelWithString:text); label.alignment = .center; label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize:15)
        body.subviews.forEach {$0.removeFromSuperview()}; label.translatesAutoresizingMaskIntoConstraints=false; body.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo:body.centerXAnchor),label.centerYAnchor.constraint(equalTo:body.centerYAnchor),label.widthAnchor.constraint(lessThanOrEqualTo:body.widthAnchor,multiplier:0.8)])
    }
    private func readText()->String? {
        guard let handle=try? FileHandle(forReadingFrom:url) else {return nil}
        defer {try? handle.close()}
        guard let data=try? handle.read(upToCount:4_194_305),data.count<=4_194_304 else {return nil}
        return String(data:data,encoding:.utf8)
    }
    private func showText(_ source:String,markdown:Bool=false) {
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=false
        let text=NSTextView(frame:NSRect(x:0,y:0,width:max(200,body.bounds.width),height:max(200,body.bounds.height)))
        text.isEditable=false; text.isSelectable=true; text.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        text.textContainerInset=NSSize(width:20,height:18); text.isVerticallyResizable=true; text.isHorizontallyResizable=false
        text.minSize = .zero; text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask=[.width]; text.textContainer?.widthTracksTextView=true
        text.textContainer?.containerSize=NSSize(width:max(200,body.bounds.width),height:CGFloat.greatestFiniteMagnitude)
        if markdown {text.textStorage?.setAttributedString(markdownStyle(source))} else {text.string=source}
        scroll.documentView=text; mount(scroll); nativeScroll=scroll; sourceText=text
        webPoll?.invalidate(); webPoll=nil
    }
    override func layout() {
        super.layout()
        guard let scroll=nativeScroll,let text=sourceText,scroll.contentSize.width>0 else {return}
        let size=scroll.contentSize
        text.minSize=NSSize(width:0,height:size.height)
        if abs(text.frame.width-size.width)>0.5 {text.setFrameSize(NSSize(width:size.width,height:max(size.height,text.frame.height)))}
    }
    private func markdownStyle(_ source:String)->NSAttributedString {
        let paragraph=NSMutableParagraphStyle(); paragraph.lineSpacing=3; paragraph.paragraphSpacing=4
        let output=NSMutableAttributedString(string:source,attributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
        // Apply styling without deleting syntax, lines, links, or unsupported Markdown.
        // Large documents keep all text; styling is bounded to avoid a long main-thread scan.
        let styledRange=NSRange(location:0,length:(String(source.prefix(128_000)) as NSString).length)
        if let headings=try? NSRegularExpression(pattern:"(?m)^#{1,6}[^\\r\\n]*") {
            for match in headings.matches(in:source,range:styledRange) {output.addAttributes([.font:NSFont.systemFont(ofSize:18,weight:.semibold)],range:match.range)}
        }
        let inlineStyles:[(String,[NSAttributedString.Key:Any])]=[
            ("`[^`\\r\\n]+`",[NSAttributedString.Key.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.systemTeal]),
            ("\\*\\*[^*\\r\\n]+\\*\\*",[NSAttributedString.Key.font:NSFont.systemFont(ofSize:14,weight:.semibold)])
        ]
        for (pattern,attributes) in inlineStyles {
            if let regex=try? NSRegularExpression(pattern:pattern) {for match in regex.matches(in:source,range:styledRange) {output.addAttributes(attributes,range:match.range)}}
        }
        return output
    }
    private func showHTML(_ source:String) {
        stopped=false; webPoll?.invalidate(); webPoll=nil; webTopSamples=0; webSampleTime = .distantPast
        webPointer=nil; webScrollGeneration += 1
        // A conservative hint for common empty app shells. It changes only the
        // explanation; valid static HTML is always still rendered below it.
        let hasScript=source.range(of:"<script\\b",options:[.regularExpression,.caseInsensitive]) != nil
        let stripped=source.replacingOccurrences(of:"(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>",with:"",options:.regularExpression)
            .replacingOccurrences(of:"(?s)<!--.*?-->|<[^>]*>",with:"",options:.regularExpression)
            .replacingOccurrences(of:"&(?:nbsp|#160|#xA0);",with:"",options:[.regularExpression,.caseInsensitive])
            .trimmingCharacters(in:.whitespacesAndNewlines)
        let emptyShell=hasScript && stripped.isEmpty
        if emptyShell {
            note.stringValue="Scroll up to return to the map · Esc"
            staticNotice.stringValue="No static page content found. Select Source to read this file."
            message("This page needs its application to display content.\nView its source here, or use Open in Default App.")
            return
        } else {
            staticNotice.stringValue="Static preview — scripts are off, so interactive charts and buttons may not work. Use Source to read the file."

            note.stringValue="Static HTML · Scripts and external assets disabled · Use Source if the page needs them"
        }
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript=false
        let view=WKWebView(frame:.zero,configuration:configuration); view.navigationDelegate=self
        web=view; mount(view)
        // Compile the blocklist before loading anything. CSP also denies file URLs,
        // frames, forms and all resources except embedded images and inline styling.
        let rules="""
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"CodeAtlasStaticHTML",encodedContentRuleList:rules) { [weak self,weak view] list,error in
            guard let self,let view,self.web === view,self.htmlMode?.selectedSegment == 0 else {return}
            guard error == nil,let list else {self.message("Static preview is unavailable. Select Source to read the HTML.");return}
            view.configuration.userContentController.add(list)
            let policy="<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'\">"
            view.loadHTMLString(policy+source,baseURL:nil)
        }
    }
    private func pollWebPosition() {
        guard !stopped,!webPollPending,let view=web,view.superview != nil,htmlMode?.selectedSegment == 0 else {return}
        webPollPending=true
        let generation=webScrollGeneration
        let point=webPointer ?? CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        let x=point.x.isFinite ? point.x : 0, y=point.y.isFinite ? point.y : 0
        // Fixed numeric-only query in an isolated client world. Inspect only the
        // pointed element's bounded ancestor chain and root, never DOM text.
        let script="""
        (() => {
          const root = document.scrollingElement;
          let maximum = Math.max(0, root ? root.scrollTop : window.scrollY);
          let element = document.elementFromPoint(\(x), \(y));
          for (let depth = 0; element && depth < 32; depth++, element = element.parentElement) {
            if (element.scrollHeight > element.clientHeight + 1) {
              const overflow = getComputedStyle(element).overflowY;
              if (overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay') {
                maximum = Math.max(maximum, element.scrollTop);
              }
            }
          }
          return maximum;
        })()
        """
        view.evaluateJavaScript(script,in:nil,in:.defaultClient) { [weak self,weak view] result in
            guard let self else {return}
            self.webPollPending=false
            guard let view,self.web === view,!self.stopped,self.webScrollGeneration==generation else {return}
            if case .success(let value)=result,let offset=value as? NSNumber {
                self.webTopSamples=offset.doubleValue<=1 ? min(2,self.webTopSamples+1) : 0
                self.webSampleTime=Date()
            } else {self.webTopSamples=0;self.webSampleTime = .distantPast}
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        guard web === webView,htmlMode?.selectedSegment == 0,!stopped else {return}
        pollWebPosition(); webPoll?.invalidate()
        let timer=Timer(timeInterval:0.1,repeats:true) { [weak self] _ in self?.pollWebPosition() }
        webPoll=timer; RunLoop.main.add(timer,forMode:.common)
    }
    private func failedHTML(_ view:WKWebView) {
        guard web === view,htmlMode?.selectedSegment == 0 else {return}
        message("The static HTML preview could not be displayed. Select Source to read this file, or open it in its default app.")
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {failedHTML(webView)}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {failedHTML(webView)}
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {failedHTML(webView)}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        // Only loadHTMLString's initial blank document may navigate inside the preview.
        let initial=navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(initial ? .allow : .cancel)
    }
}
