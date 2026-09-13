import Foundation

/// The same physical direction applies to map, source and media views.
public enum MapZoom {
    public static func factor(deltaY:Double) -> Double {
        guard deltaY.isFinite else {return 1}
        return exp(min(0.18,max(-0.18,-deltaY*0.008)))
    }
}

/// Gates transition actions only; rejected events may still scroll native content.
/// A fresh gesture or a deliberate reversal can start another navigation action.
public struct PreviewGestureGate {
    private enum Mode {case idle, entering, exiting}
    private var mode:Mode = .idle
    private var lastEvent:Double=0
    public init() {}
    public mutating func enter(at time:Double) {mode = .entering; lastEvent=time}
    public mutating func exit(at time:Double) {mode = .exiting; lastEvent=time}
    public mutating func accepts(deltaY:Double,isMomentum:Bool,phaseBegan:Bool,isUnphased:Bool,at time:Double) -> Bool {
        guard deltaY.isFinite, time.isFinite else {return false}
        let gap=time-lastEvent
        lastEvent=time
        // Inertia must never trigger entry/exit, even after an idle gap.
        guard !isMomentum else {return false}
        if phaseBegan || (isUnphased && gap>=0.25) {mode = .idle}
        switch mode {
        case .idle: return true
        case .entering:
            // The downward gesture which opened the file may continue reading it.
            return deltaY<=0
        case .exiting:
            // Upward continuation cannot reopen the file; reversal is intentional.
            if deltaY<0 {mode = .idle;return true}
            return false
        }
    }
}
