import AppKit
import AtlasCore

/// A bounded, in-memory view of supplied relationships. It creates no graph data.
final class PersonalConnectionsView:NSView {
    var projection:PersonalProjection? {didSet {rebuild()}}
    var selectedID:String? {didSet {updateSelection()}}
    var onSelect:((String)->Void)?
    private var cards:[String:ConnectionCard]=[:]
    private var nodeRects:[String:CGRect]=[:]
    private var nodeOrder:[String]=[]
    private var groups:[(String,CGRect)]=[]
    private var worldBounds=CGRect(x:0,y:0,width:1,height:1)
    private var center=CGPoint.zero
    private var zoom:CGFloat=1
    private var dragPoint:CGPoint?
    private var lastSize=CGSize.zero
    private var fitting=true
    private var cameraTimer:Timer?
    private var neighbors=Set<String>()
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true;layer?.masksToBounds=true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Personal connections. Scroll down to zoom in. Drag empty space to pan. Arrow keys choose an area; Escape fits the map.")
    }
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError()}
    deinit {cameraTimer?.invalidate()}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {stopCamera()}
    }
    private func stopCamera() {cameraTimer?.invalidate();cameraTimer=nil}
    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize=bounds.size
            stopCamera()
            if fitting {fit(animated:false)} else {positionCards()}
        }
    }
    private func rebuild() {
        stopCamera();dragPoint=nil
        cards.values.forEach {$0.removeFromSuperview()};cards=[:];nodeRects=[:];nodeOrder=[];groups=[]
        guard let projection,!projection.areas.isEmpty else {selectedID=nil;needsDisplay=true;return}
        // Deduplicate malformed IDs without inventing extra entities.
        var seen=Set<String>()
        let areas=projection.areas.prefix(24).filter {seen.insert($0.id).inserted}
        let types=["area","goal","responsibility","person","thread","event","drift"]
        let connected=Dictionary(grouping:projection.links.flatMap {[$0.from,$0.to]},by:{$0}).mapValues(\.count)
        var column=0
        for kind in types {
            let members=areas.filter {$0.kind==kind}.sorted {
                let a=connected[$0.id,default:0], b=connected[$1.id,default:0]
                if a != b {return a>b}
                if $0.name != $1.name {return $0.name<$1.name}
                return $0.id<$1.id
            }
            guard !members.isEmpty else {continue}
            // Tall categories wrap into bounded subcolumns, so every node can fit.
            let columnCount=max(1,Int(ceil(Double(members.count)/6)))
            let x=CGFloat(column)*276
            groups.append((kind.capitalized,CGRect(x:x,y:0,width:CGFloat(columnCount)*276-32,height:26)))
            for (offset,area) in members.enumerated() {
                let rect=CGRect(x:x+CGFloat(offset/6)*276,y:40+CGFloat(offset%6)*126,width:244,height:96)
                nodeRects[area.id]=rect;nodeOrder.append(area.id)
                let card=ConnectionCard(area:area)
                card.onActivate={ [weak self] in self?.choose(area.id) }
                card.onKey={ [weak self] key in self?.navigate(key) }
                cards[area.id]=card;addSubview(card)
            }
            column += columnCount
        }
        worldBounds=nodeRects.values.reduce(CGRect.null) {$0.union($1)}.union(CGRect(x:0,y:0,width:1,height:1))
        if let selectedID,!seen.contains(selectedID) {self.selectedID=nil}
        updateSelection();fit(animated:false)
    }
    private func updateSelection() {
        neighbors=Set(selectedID.map {[$0]} ?? [])
        if let id=selectedID {
            for link in projection?.links ?? [] where link.from==id || link.to==id {
                neighbors.insert(link.from);neighbors.insert(link.to)
            }
        }
        for (id,card) in cards {
            card.chosen=id==selectedID
            card.dimmed=selectedID != nil && !neighbors.contains(id)
            card.needsDisplay=true
        }
        needsDisplay=true
    }
    func fit() {fit(animated:true)}
    private func fit(animated:Bool) {
        guard !nodeRects.isEmpty,bounds.width>1,bounds.height>1 else {needsDisplay=true;return}
        fitting=true
        let scale=min(1.15,max(0.08,min((bounds.width-64)/max(1,worldBounds.width),(bounds.height-70)/max(1,worldBounds.height))))
        moveCamera(to:CGPoint(x:worldBounds.midX,y:worldBounds.midY),scale:scale,animated:animated)
    }
    func focus(id:String) {
        guard let rect=nodeRects[id] else {return}
        fitting=false
        let destination=CGPoint(x:rect.midX,y:rect.midY)
        let linked=Set((projection?.links ?? []).compactMap {link -> String? in
            if link.from==id {return link.to}
            if link.to==id {return link.from}
            return nil
        })
        // Keep the nearest supplied neighbors visible instead of filling the canvas
        // with a single card. The selected card remains centered.
        let nearby=linked.compactMap {nodeRects[$0]}.sorted {
            let a=hypot($0.midX-destination.x,$0.midY-destination.y),b=hypot($1.midX-destination.x,$1.midY-destination.y)
            if a != b {return a<b}
            return $0.minX == $1.minX ? $0.minY<$1.minY : $0.minX<$1.minX
        }.prefix(2)
        let neighborhood=nearby.reduce(rect.insetBy(dx:-100,dy:-75)) {$0.union($1)}
        let width=2*max(destination.x-neighborhood.minX,neighborhood.maxX-destination.x)
        let height=2*max(destination.y-neighborhood.minY,neighborhood.maxY-destination.y)
        let scale=min(1.15,max(0.08,min((bounds.width-90)/max(1,width),(bounds.height-90)/max(1,height))))
        moveCamera(to:destination,scale:scale,animated:true)
    }
    private func moveCamera(to destination:CGPoint,scale:CGFloat,animated:Bool) {
        stopCamera()
        guard animated,window != nil,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            center=destination;zoom=scale;positionCards();return
        }
        let origin=center,initialZoom=zoom,start=ProcessInfo.processInfo.systemUptime
        // Capture scalar camera state only; the run loop never retains graph content.
        let timer=Timer(timeInterval:1.0/120,repeats:true) { [weak self] timer in
            guard let self else {timer.invalidate();return}
            let t=min(1,max(0,(ProcessInfo.processInfo.systemUptime-start)/0.24))
            let ease=t*t*(3-2*t)
            self.center=CGPoint(x:origin.x+(destination.x-origin.x)*ease,y:origin.y+(destination.y-origin.y)*ease)
            self.zoom=exp(log(initialZoom)+(log(scale)-log(initialZoom))*ease)
            self.positionCards()
            if t>=1 {timer.invalidate();self.cameraTimer=nil}
        }
        cameraTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func screen(_ point:CGPoint)->CGPoint {
        CGPoint(x:bounds.midX+(point.x-center.x)*zoom,y:bounds.midY+(point.y-center.y)*zoom)
    }
    private func world(_ point:CGPoint)->CGPoint {
        CGPoint(x:center.x+(point.x-bounds.midX)/zoom,y:center.y+(point.y-bounds.midY)/zoom)
    }
    private func positionCards() {
        for (id,card) in cards {
            guard let rect=nodeRects[id] else {continue}
            card.frame=CGRect(origin:screen(rect.origin),size:CGSize(width:rect.width*zoom,height:rect.height*zoom))
            card.scale=zoom;card.needsDisplay=true
        }
        needsDisplay=true
    }
    private func choose(_ id:String) {
        selectedID=id;onSelect?(id)
    }
    private func navigate(_ key:UInt16) {
        if key==53 {fit();return}
        guard !nodeOrder.isEmpty else {return}
        let current=selectedID.flatMap {nodeOrder.firstIndex(of:$0)} ?? -1
        let direction=(key==123 || key==126) ? -1 : 1
        let next=current<0 ? (direction>0 ? 0:nodeOrder.count-1) : (current+direction+nodeOrder.count)%nodeOrder.count
        let id=nodeOrder[next];choose(id);focus(id:id);window?.makeFirstResponder(cards[id])
    }
    override func keyDown(with event:NSEvent) {
        if [UInt16(123),124,125,126,53].contains(event.keyCode) {navigate(event.keyCode)} else {super.keyDown(with:event)}
    }
    override func mouseDown(with event:NSEvent) {stopCamera();window?.makeFirstResponder(self);dragPoint=convert(event.locationInWindow,from:nil)}
    override func mouseDragged(with event:NSEvent) {
        stopCamera()
        let point=convert(event.locationInWindow,from:nil)
        if let old=dragPoint {fitting=false;center.x-=(point.x-old.x)/zoom;center.y-=(point.y-old.y)/zoom;positionCards()}
        dragPoint=point
    }
    override func mouseUp(with event:NSEvent) {dragPoint=nil}
    private func scale(_ factor:CGFloat,at point:CGPoint) {
        stopCamera()
        let before=world(point);fitting=false;zoom=min(3,max(0.08,zoom*factor));let after=world(point)
        center.x+=before.x-after.x;center.y+=before.y-after.y;positionCards()
    }
    override func scrollWheel(with event:NSEvent) {scale(CGFloat(MapZoom.factor(deltaY:Double(event.scrollingDeltaY))),at:convert(event.locationInWindow,from:nil))}
    override func magnify(with event:NSEvent) {scale(max(0.1,1+event.magnification),at:convert(event.locationInWindow,from:nil))}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedRed:0.035,green:0.052,blue:0.075,alpha:1).setFill();bounds.fill()
        guard !cards.isEmpty else {
            let text="Your connections will appear here\nSearch Personal to explore its evidence."
            (text as NSString).draw(in:bounds.insetBy(dx:28,dy:36),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.secondaryLabelColor]);return
        }
        NSGraphicsContext.saveGraphicsState();defer {NSGraphicsContext.restoreGraphicsState()};NSBezierPath(rect:bounds).addClip()
        // All arrows are actual supplied links. Draw behind the native card views.
        for link in projection?.links ?? [] {
            guard let a=nodeRects[link.from],let b=nodeRects[link.to] else {continue}
            let strong=selectedID==nil || link.from==selectedID || link.to==selectedID
            let color=NSColor.systemTeal.withAlphaComponent(strong ? 0.72 : 0.10)
            let start:CGPoint,end:CGPoint,controlA:CGPoint,controlB:CGPoint
            if link.from==link.to {
                start=screen(CGPoint(x:a.maxX,y:a.midY-12));end=screen(CGPoint(x:a.maxX,y:a.midY+12))
                controlA=CGPoint(x:start.x+42*zoom,y:start.y-30*zoom);controlB=CGPoint(x:end.x+42*zoom,y:end.y+30*zoom)
            } else if abs(a.midX-b.midX)>a.width/2 {
                let forward=b.midX>a.midX
                start=screen(CGPoint(x:forward ? a.maxX:a.minX,y:a.midY));end=screen(CGPoint(x:forward ? b.minX:b.maxX,y:b.midY))
                let bend=max(24*zoom,abs(end.x-start.x)*0.48)*(forward ? 1:-1)
                controlA=CGPoint(x:start.x+bend,y:start.y);controlB=CGPoint(x:end.x-bend,y:end.y)
            } else {
                let down=b.midY>a.midY
                start=screen(CGPoint(x:a.midX,y:down ? a.maxY:a.minY));end=screen(CGPoint(x:b.midX,y:down ? b.minY:b.maxY))
                controlA=CGPoint(x:start.x,y:(start.y+end.y)/2);controlB=CGPoint(x:end.x,y:(start.y+end.y)/2)
            }
            let path=NSBezierPath();path.lineWidth=strong ? 1.7:1;path.move(to:start);path.curve(to:end,controlPoint1:controlA,controlPoint2:controlB);color.setStroke();path.stroke()
            let angle=atan2(end.y-controlB.y,end.x-controlB.x),length=max(4,7*zoom)
            let arrow=NSBezierPath();arrow.move(to:end);arrow.line(to:CGPoint(x:end.x-length*cos(angle-0.48),y:end.y-length*sin(angle-0.48)));arrow.line(to:CGPoint(x:end.x-length*cos(angle+0.48),y:end.y-length*sin(angle+0.48)));arrow.close();color.setFill();arrow.fill()
            if strong,selectedID != nil,zoom>0.7,link.from != link.to {
                let label=link.kind.replacingOccurrences(of:"_",with:" ")
                let point=CGPoint(x:(start.x+end.x)/2+5,y:(start.y+end.y)/2-16)
                (label as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.systemTeal])
            }
        }
        for (title,rect) in groups {
            (title.uppercased() as NSString).draw(at:screen(rect.origin),withAttributes:[.font:NSFont.systemFont(ofSize:max(9,11*zoom),weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor])
        }
    }
}

private final class ConnectionCard:NSButton {
    override var acceptsFirstResponder:Bool {true}
    let area:PersonalArea
    var onActivate:(()->Void)?
    var onKey:((UInt16)->Void)?
    var chosen=false
    var dimmed=false
    var scale:CGFloat=1
    init(area:PersonalArea) {
        self.area=area;super.init(frame:.zero)
        title=area.name;isBordered=false;setButtonType(.momentaryPushIn);target=self;action=#selector(activate)
        setAccessibilityLabel("\(area.name), \(area.kind), \(area.claims.count) \(area.claims.count==1 ? "claim":"claims"), \(area.sources.count) \(area.sources.count==1 ? "source":"sources")")
        setAccessibilityHelp("Select to inspect evidence and connected areas.")
        toolTip=area.name
    }
    required init?(coder:NSCoder) {fatalError()}
    @objc private func activate() {onActivate?()}
    override func keyDown(with event:NSEvent) {
        if [UInt16(123),124,125,126,53].contains(event.keyCode) {onKey?(event.keyCode)} else {super.keyDown(with:event)}
    }
    override func draw(_ dirtyRect:NSRect) {
        let rect=bounds.insetBy(dx:1,dy:1),radius=max(4,11*scale)
        let path=NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius)
        NSColor(calibratedRed:chosen ? 0.08:0.07,green:chosen ? 0.23:0.12,blue:chosen ? 0.28:0.18,alpha:dimmed ? 0.55:1).setFill();path.fill()
        (chosen ? NSColor.systemTeal:NSColor.white.withAlphaComponent(0.12)).setStroke();path.lineWidth=chosen ? 2:1;path.stroke()
        let inset=max(5,13*scale)
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let color=NSColor.white.withAlphaComponent(dimmed ? 0.40:0.94)
        let titleRect=CGRect(x:inset,y:bounds.height*0.36,width:max(1,bounds.width-2*inset),height:bounds.height*0.47)
        (area.name as NSString).draw(in:titleRect,withAttributes:[.font:NSFont.systemFont(ofSize:max(8,14*scale),weight:.semibold),.foregroundColor:color,.paragraphStyle:paragraph])
        let detail="\(area.kind.uppercased())  ·  \(area.sources.count) \(area.sources.count==1 ? "source":"sources")"
        (detail as NSString).draw(in:CGRect(x:inset,y:bounds.height*0.10,width:max(1,bounds.width-2*inset),height:max(10,16*scale)),withAttributes:[.font:NSFont.systemFont(ofSize:max(7,10*scale),weight:.medium),.foregroundColor:NSColor.systemTeal.withAlphaComponent(dimmed ? 0.35:0.85),.paragraphStyle:paragraph])
        if window?.firstResponder === self {NSColor.keyboardFocusIndicatorColor.setStroke();let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:radius,yRadius:radius);focus.lineWidth=2;focus.stroke()}
    }
}
