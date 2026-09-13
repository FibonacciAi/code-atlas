import XCTest
@testable import AtlasCore

final class PreviewGestureTests:XCTestCase {
    func testDownEntersMapAndUpZoomsOut() {
        XCTAssertGreaterThan(MapZoom.factor(deltaY:-8),1)
        XCTAssertLessThan(MapZoom.factor(deltaY:8),1)
        XCTAssertEqual(MapZoom.factor(deltaY:0),1)
        XCTAssertEqual(MapZoom.factor(deltaY:8)*MapZoom.factor(deltaY:-8),1,accuracy:0.00001)
        XCTAssertEqual(MapZoom.factor(deltaY:-100_000),exp(0.18),accuracy:0.00001)
        XCTAssertEqual(MapZoom.factor(deltaY:.infinity),1)
    }
    func testOpeningGestureContinuesReadingButCannotImmediatelyPullOut() {
        var gate=PreviewGestureGate();gate.enter(at:10)
        XCTAssertTrue(gate.accepts(deltaY:-20,isMomentum:false,phaseBegan:false,isUnphased:false,at:10.01))
        XCTAssertFalse(gate.accepts(deltaY:20,isMomentum:false,phaseBegan:false,isUnphased:false,at:10.02))
        XCTAssertFalse(gate.accepts(deltaY:100,isMomentum:true,phaseBegan:false,isUnphased:false,at:10.03))
        XCTAssertTrue(gate.accepts(deltaY:20,isMomentum:false,phaseBegan:true,isUnphased:false,at:10.1))
    }
    func testExitRemainderCannotReopenUntilDeliberateReversal() {
        var gate=PreviewGestureGate();gate.exit(at:10)
        XCTAssertFalse(gate.accepts(deltaY:20,isMomentum:false,phaseBegan:false,isUnphased:false,at:10.01))
        XCTAssertFalse(gate.accepts(deltaY:-20,isMomentum:true,phaseBegan:false,isUnphased:false,at:10.02))
        XCTAssertTrue(gate.accepts(deltaY:-20,isMomentum:false,phaseBegan:false,isUnphased:false,at:10.03))
    }
    func testWheelIdleIsMeasuredFromLastEventNotTransitionAge() {
        var gate=PreviewGestureGate();gate.exit(at:10)
        for n in 1...8 {
            XCTAssertFalse(gate.accepts(deltaY:3,isMomentum:false,phaseBegan:false,isUnphased:true,at:10+Double(n)*0.1))
        }
        XCTAssertTrue(gate.accepts(deltaY:3,isMomentum:false,phaseBegan:false,isUnphased:true,at:11.2))
    }
    func testFreshGestureAllowsExitButMomentumNeverDoes() {
        var gate=PreviewGestureGate();gate.exit(at:10)
        XCTAssertFalse(gate.accepts(deltaY:100,isMomentum:true,phaseBegan:true,isUnphased:true,at:11))
        XCTAssertTrue(gate.accepts(deltaY:20,isMomentum:false,phaseBegan:true,isUnphased:false,at:11.01))
    }
    func testCanvasAndDocumentUseSameUpwardPullWithDifferentTopConstraint() {
        var canvas=SourcePull(), document=SourcePull()
        XCTAssertFalse(canvas.update(deltaY:-100,atTop:true,isMomentum:false))
        XCTAssertFalse(document.update(deltaY:100,atTop:false,isMomentum:false))
        XCTAssertTrue(canvas.update(deltaY:100,atTop:true,isMomentum:false))
        XCTAssertTrue(document.update(deltaY:100,atTop:true,isMomentum:false))
    }
}
