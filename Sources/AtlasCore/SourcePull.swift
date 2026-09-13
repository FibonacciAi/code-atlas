import Foundation

/// Deliberate upward overscroll exits; inertia and ordinary document scrolling do not.
public struct SourcePull {
    public private(set) var distance:Double=0
    public let threshold:Double
    public init(threshold:Double=72) {self.threshold=threshold}
    public mutating func reset() {distance=0}
    public mutating func update(deltaY:Double,atTop:Bool,isMomentum:Bool) -> Bool {
        guard atTop, !isMomentum, deltaY>0 else {reset();return false}
        distance += deltaY
        return distance>=threshold
    }
}
