import XCTest
@testable import AtlasCore

final class PreviewResidencyTests: XCTestCase {
    func testSeventyVisibleThumbnailsDoNotEvictEachOther() {
        var cache = PreviewResidency<Int>(capacity: 128)
        let visible = Array(0..<70)
        cache.retainVisible(visible)
        for id in 0..<128 { XCTAssertNotNil(cache.insert(id)) }
        let originalSlots = visible.map { cache.slot(for: $0) }
        // Simulate late completions from several previously visited viewports.
        for id in 128..<500 { XCTAssertNotNil(cache.insert(id)) }
        XCTAssertEqual(visible.map { cache.slot(for: $0) }, originalSlots)
        XCTAssertEqual(cache.count, 128)
    }

    func testViewportReversalRetainsRecentImagesAndReusesOldSlots() {
        var cache = PreviewResidency<Int>(capacity: 4)
        for id in 0..<4 { _ = cache.insert(id) }
        cache.retainVisible([0, 1])
        let protected = [cache.slot(for: 0), cache.slot(for: 1)]
        XCTAssertEqual(cache.insert(4), 2)
        XCTAssertEqual(cache.insert(5), 3)
        XCTAssertEqual([cache.slot(for: 0), cache.slot(for: 1)], protected)
        cache.retainVisible([4, 5])
        XCTAssertEqual(cache.insert(6), 0)
        XCTAssertEqual(cache.insert(7), 1)
        XCTAssertEqual(Set(cache.residentKeys.compactMap { cache.slot(for: $0) }).count, 4)
    }

    func testAllPinnedDropsLateCompletionInsteadOfBlankingViewport() {
        var cache = PreviewResidency<Int>(capacity: 2)
        _ = cache.insert(0); _ = cache.insert(1)
        cache.retainVisible([0, 1])
        XCTAssertNil(cache.insert(2))
        XCTAssertEqual(cache.residentKeys, [0, 1])
        XCTAssertEqual(cache.insert(0), 0)
    }
}
