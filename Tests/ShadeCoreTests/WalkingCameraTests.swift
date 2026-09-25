import XCTest
@testable import ShadeCore
final class WalkingCameraTests:XCTestCase {
    func testSanFranciscoFixCannotFollowDubaiRoute() throws {
        let p=CoordinateProjection(origin:.init(latitude:25.2074,longitude:55.2637))
        let route=[LocalPoint(x:0,y:0),LocalPoint(x:800,y:0)]
        let far=p.geoToLocal(.init(latitude:37.788,longitude:-122.407))
        let progress=try XCTUnwrap(WalkingProgress.calculate(point:far,route:route,expectedSeconds:1200))
        XCTAssertFalse(progress.canFollowLocation)
    }
    func testNearbyFixCanFollowButDistantFixCannot() throws {
        let route=[LocalPoint(x:0,y:0),LocalPoint(x:1000,y:0)]
        for (distance,expected) in [(0.0,true),(45,true),(250,true),(251,false),(10000,false)] {
            let progress=try XCTUnwrap(WalkingProgress.calculate(point:.init(x:400,y:distance),route:route,expectedSeconds:600))
            XCTAssertEqual(progress.canFollowLocation,expected)
        }
    }
}
