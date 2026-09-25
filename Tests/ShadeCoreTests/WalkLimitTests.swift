import XCTest
@testable import ShadeCore
final class WalkLimitTests:XCTestCase {
    func testOneHourBoundaryAndInvalidDurations() {
        XCTAssertTrue(WalkLimit.allows(seconds:60))
        XCTAssertTrue(WalkLimit.allows(seconds:3600))
        XCTAssertFalse(WalkLimit.allows(seconds:3601))
        XCTAssertFalse(WalkLimit.allows(seconds:0))
        XCTAssertFalse(WalkLimit.allows(seconds:Double.nan))
        XCTAssertFalse(WalkLimit.allows(seconds:Double.infinity))
    }
}
