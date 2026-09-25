import XCTest
@testable import ShadeCore
final class SolarPositionTests: XCTestCase {
    let dubai = GeoPoint(latitude:25.2,longitude:55.27)
    func solar(_ hour: Int) -> SolarPosition {
        let date = ISO8601DateFormatter().date(from:String(format:"2026-09-24T%02d:00:00+04:00",hour))!
        return SolarPositionService.position(at:date,coordinate:dubai)
    }
    func testDubaiDayAndNight() {
        let morning = solar(9), noon = solar(12), afternoon = solar(16)
        XCTAssertGreaterThan(morning.elevationDegrees,0); XCTAssertLessThan(solar(0).elevationDegrees,0)
        XCTAssertTrue((0..<180).contains(morning.azimuthDegrees)); XCTAssertTrue((180..<360).contains(afternoon.azimuthDegrees))
        XCTAssertGreaterThan(noon.elevationDegrees,60)
        XCTAssertGreaterThan(noon.elevationDegrees,morning.elevationDegrees)
        XCTAssertGreaterThan(noon.elevationDegrees,afternoon.elevationDegrees)
        XCTAssertGreaterThan(20/tan(afternoon.elevationDegrees * .pi/180),20/tan(noon.elevationDegrees * .pi/180))
        print("Dubai solar: 09:00 \(morning); 12:00 \(noon); 16:00 \(afternoon)")
    }
    func testRealSolarRotatesSyntheticShadow() {
        let building = BuildingGeometry(id:"test",footprint:[.init(x:0,y:0),.init(x:20,y:0),.init(x:20,y:20),.init(x:0,y:20)],heightMeters:20)
        let engine = ShadeEngine()
        for hour in [9,12,16] {
            let sun = solar(hour), distance = 20/tan(sun.elevationDegrees * .pi/180)
            let center = LocalPoint(x:10,y:10)
            let p = center-sun.direction*(distance*0.5+10)
            XCTAssertTrue(engine.isPointShaded(p,solar:sun,buildings:[building]))
        }
        XCTAssertTrue(engine.isPointShaded(.init(x:35,y:10),solar:solar(16),buildings:[building]))
        XCTAssertFalse(engine.isPointShaded(.init(x:35,y:10),solar:solar(12),buildings:[building]))
    }
    func testNRELPublishedReference() {
        // NREL SPA report example: 2003-10-17 12:30:30 MST, 39.742476 N, 105.1786 W.
        // Published apparent zenith 50.11162°, azimuth 194.34024°. Our geometric elevation
        // excludes refraction, so a 0.05° tolerance includes that intentional difference.
        let date = ISO8601DateFormatter().date(from:"2003-10-17T19:30:30Z")!
        let result = SolarPositionService.position(at:date,coordinate:.init(latitude:39.742476,longitude:-105.1786))
        XCTAssertEqual(result.azimuthDegrees,194.34024,accuracy:0.05)
        XCTAssertEqual(result.elevationDegrees,90-50.11162,accuracy:0.05)
    }
    func testUTCEqualsDubaiInstant() {
        let formatter = ISO8601DateFormatter()
        let a = SolarPositionService.position(at:formatter.date(from:"2026-09-24T12:00:00+04:00")!,coordinate:dubai)
        let b = SolarPositionService.position(at:formatter.date(from:"2026-09-24T08:00:00Z")!,coordinate:dubai)
        XCTAssertEqual(a.elevationDegrees,b.elevationDegrees)
    }
}
