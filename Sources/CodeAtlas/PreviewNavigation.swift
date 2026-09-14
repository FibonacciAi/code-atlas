import AppKit
import AtlasCore

/// One navigation boundary around native text, WebKit, PDF and AVKit content.
/// Native views retain normal scrolling; only deliberate top overscroll exits.
final class PreviewNavigation {
    private weak var view:NSView?
    private let position:()->PreviewScrollPosition
    private let prepare:(NSEvent)->Void
    private let progress:(Double)->Void
    private let exit:()->Void
    private var monitor:Any?
    private var pull=SourcePull()
    private var gate=PreviewGestureGate()
    private var pinch:CGFloat=0

    init(view:NSView,position:@escaping()->PreviewScrollPosition,prepare:@escaping(NSEvent)->Void,progress:@escaping(Double)->Void,exit:@escaping()->Void) {
        self.view=view; self.position=position; self.prepare=prepare; self.progress=progress; self.exit=exit
        gate.enter(at:ProcessInfo.processInfo.systemUptime)
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.magnify,.keyDown]) { [weak self] event in
            guard let self else {return event}
            return self.handle(event)
        }
    }
    deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    private func handle(_ event:NSEvent)->NSEvent? {
        guard let view,!view.isHiddenOrHasHiddenAncestor,let window=view.window,event.window === window else {return event}
        // WebKit and AVKit do not reliably forward cancelOperation up the chain.
        if event.type == .keyDown {
            if event.keyCode == 53 {exit();return nil}
            return event
        }
        guard view.bounds.contains(view.convert(event.locationInWindow,from:nil)) else {return event}
        if event.type == .magnify {
            if event.phase == .began {pinch=0}
            pinch=min(0,pinch+event.magnification)
            if pinch < -0.10 {exit()}
            return nil
        }
        let delta=Double(event.scrollingDeltaY)*(event.hasPreciseScrollingDeltas ? 1 : 12)
        prepare(event)
        if event.phase == .began {pull.reset();progress(0)}
        let canExit=gate.accepts(deltaY:delta,isMomentum:!event.momentumPhase.isEmpty,phaseBegan:event.phase == .began,isUnphased:event.phase.isEmpty,at:ProcessInfo.processInfo.systemUptime)
        let atTop:Bool,canvas:Bool
        switch position() {
        case .canvas: atTop=true;canvas=true
        case .document(let top): atTop=top;canvas=false
        }
        if canExit && pull.update(deltaY:delta,atTop:atTop,isMomentum:false) {exit();return nil}
        if !canExit {pull.reset()}
        progress(min(1,pull.distance/pull.threshold))
        // Preserve native document inertia; it cannot itself close the preview.
        if canvas || (canExit && atTop && delta>0) {return nil}
        return event
    }
}
