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
    func testOnRouteTimeStaysZero() {
        var tracker=OffRouteTracker()
        let start=Date(timeIntervalSince1970:1000)
        for (elapsed,distance) in [(0.0,0.0),(15.0,10.0),(30.0,25.0)] {
            let result=tracker.update(distanceOffRoute:distance,at:start.addingTimeInterval(elapsed))
            XCTAssertEqual(result.meters,distance)
            XCTAssertEqual(result.seconds,0)
        }
    }
    func testOffRouteTimeAccumulates() {
        var tracker=OffRouteTracker()
        let start=Date(timeIntervalSince1970:1000)
        XCTAssertEqual(tracker.update(distanceOffRoute:40,at:start).seconds,0)
        XCTAssertEqual(tracker.update(distanceOffRoute:50,at:start.addingTimeInterval(15)).seconds,15)
        let result=tracker.update(distanceOffRoute:40,at:start.addingTimeInterval(30))
        XCTAssertEqual(result.meters,40)
        XCTAssertEqual(result.seconds,30)
    }
    func testReturningToRouteResetsClock() {
        var tracker=OffRouteTracker()
        let start=Date(timeIntervalSince1970:1000)
        _=tracker.update(distanceOffRoute:40,at:start)
        XCTAssertEqual(tracker.update(distanceOffRoute:40,at:start.addingTimeInterval(30)).seconds,30)
        XCTAssertEqual(tracker.update(distanceOffRoute:25,at:start.addingTimeInterval(40)).seconds,0)
        XCTAssertEqual(tracker.update(distanceOffRoute:10,at:start.addingTimeInterval(50)).seconds,0)
        XCTAssertEqual(tracker.update(distanceOffRoute:40,at:start.addingTimeInterval(60)).seconds,0)
        XCTAssertEqual(tracker.update(distanceOffRoute:40,at:start.addingTimeInterval(70)).seconds,10)
    }
    func testOffRouteTimeCannotBeNegative() {
        var tracker=OffRouteTracker()
        let start=Date(timeIntervalSince1970:1000)
        _=tracker.update(distanceOffRoute:40,at:start)
        XCTAssertEqual(tracker.update(distanceOffRoute:40,at:start.addingTimeInterval(-10)).seconds,0)
    }
}
