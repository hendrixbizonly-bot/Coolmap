import XCTest
@testable import ShadeCore
final class DataTests: XCTestCase {
    func testInvalidPolygons() {
        XCTAssertFalse(PolygonGeometry.isValid([.init(x:0,y:0),.init(x:20,y:20),.init(x:0,y:20),.init(x:30,y:0)]))
        XCTAssertFalse(PolygonGeometry.isValid([.init(x:0,y:0),.init(x:1,y:0),.init(x:2,y:0)]))
    }
    func testHeightUnits() {
        XCTAssertEqual(HeightParser.meters("15"),15)
        XCTAssertEqual(HeightParser.meters("15 m"),15)
        XCTAssertEqual(HeightParser.meters("50 ft")!,15.24,accuracy:0.00001)
        XCTAssertNil(HeightParser.meters("unknown")); XCTAssertNil(HeightParser.meters("-3"))
    }
    func testUnequalIntervalsAndNight() {
        let result = RouteExposureService.calculate(points:[.init(x:0,y:0),.init(x:1,y:0),.init(x:100,y:0)],expectedTravelTime:600,buildings:[]) { _,_ in .init(azimuthDegrees:0,elevationDegrees:-5) }
        XCTAssertEqual(result.shadeDistance,100,accuracy:1e-6); XCTAssertEqual(result.sunSeconds,0)
    }
    func testFartherTallBuildingStillBlocks() {
        func b(_ id: String,_ y:Double,_ height:Double) -> BuildingGeometry { .init(id:id,footprint:[.init(x:0,y:y),.init(x:20,y:y),.init(x:20,y:y+5),.init(x:0,y:y+5)],heightMeters:height) }
        let decision = ShadeEngine().classify(.init(x:10,y:40),solar:.init(azimuthDegrees:180,elevationDegrees:45),buildings:[b("short",20,2),b("tall",0,60)])
        XCTAssertEqual(decision.buildingID,"tall")
    }
}
