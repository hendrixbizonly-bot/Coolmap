import XCTest
@testable import ShadeCore
final class GeometryTests: XCTestCase {
    let building = BuildingGeometry(id: "test", footprint: [.init(x:0,y:0),.init(x:20,y:0),.init(x:20,y:20),.init(x:0,y:20)], heightMeters: 20)
    func testProjection() {
        let projection = CoordinateProjection(origin: .init(latitude:25.2,longitude:55.27))
        let geo = projection.localToGeo(.init(x:100,y:50))
        let local = projection.geoToLocal(geo)
        XCTAssertEqual(local.x,100,accuracy:1e-6); XCTAssertEqual(local.y,50,accuracy:1e-6)
    }
    func testRayCases() {
        let o = LocalPoint(x:0,y:0), d = LocalPoint(x:1,y:0)
        XCTAssertEqual(RayIntersection.segment(origin:o,direction:d,a:.init(x:10,y:-1),b:.init(x:10,y:1)),10)
        XCTAssertNil(RayIntersection.segment(origin:o,direction:d,a:.init(x:-10,y:-1),b:.init(x:-10,y:1)))
        XCTAssertNil(RayIntersection.segment(origin:o,direction:d,a:.init(x:1,y:1),b:.init(x:10,y:1)))
        XCTAssertEqual(RayIntersection.segment(origin:o,direction:d,a:.init(x:10,y:0),b:.init(x:10,y:1)),10)
        XCTAssertEqual(RayIntersection.segment(origin:o,direction:d,a:.init(x:5,y:0),b:.init(x:10,y:0)),5)
        XCTAssertNil(RayIntersection.segment(origin:o,direction:.init(x:-1,y:0),a:.init(x:10,y:-1),b:.init(x:10,y:1)))
    }
    func assertShade(_ x: Double, _ y: Double, _ azimuth: Double, _ elevation: Double, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ShadeEngine().isPointShaded(.init(x:x,y:y),solar:.init(azimuthDegrees:azimuth,elevationDegrees:elevation),buildings:[building]),expected,file:file,line:line)
    }
    func test1Simple45DegreeShadow() { assertShade(10,30,180,45,true); assertShade(10,45,180,45,false) }
    func test2HighSun() { assertShade(10,25,180,63.4349,true); assertShade(10,35,180,63.4349,false) }
    func test3LowSun() { assertShade(10,50,180,26.565,true); assertShade(10,70,180,26.565,false) }
    func test4Direction() { assertShade(-10,10,90,45,true); assertShade(30,10,90,45,false); assertShade(30,10,270,45,true); assertShade(-10,10,270,45,false) }
    func test5Night() { assertShade(1000,1000,180,-5,true) }
}
final class RouteExposureTests: XCTestCase {
    func test6DistanceWeightedExposure() {
        let b = BuildingGeometry(id:"wall",footprint:[.init(x:0,y:0),.init(x:40,y:0),.init(x:40,y:20),.init(x:0,y:20)],heightMeters:20)
        let result = RouteExposureService.calculate(points:[.init(x:0,y:30),.init(x:100,y:30)],expectedTravelTime:600,buildings:[b]) { _,_ in .init(azimuthDegrees:180,elevationDegrees:45) }
        XCTAssertEqual(result.sunDistance,60,accuracy:0.01)
        XCTAssertEqual(result.shadeDistance,40,accuracy:0.01)
        XCTAssertEqual(result.sunSeconds,360,accuracy:0.01)
        XCTAssertEqual(result.shadeSeconds,240,accuracy:0.01)
    }
}
