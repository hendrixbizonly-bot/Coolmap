import XCTest
@testable import ShadeCore
final class RealRouteTests: XCTestCase {
    struct RecordedRoute: Decodable { let coordinates: [GeoPoint]; let travelSeconds: Double }
    func testRecordedMapKitRoutesChangeWithTime() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let records = try JSONDecoder().decode([BuildingRecord].self,from:Data(contentsOf:root.appendingPathComponent("CoolMap/Resources/buildings.json")))
        let routes = try JSONDecoder().decode([RecordedRoute].self,from:Data(contentsOf:root.appendingPathComponent("Verification/noon.json")))
        let projection = CoordinateProjection(origin:routes[0].coordinates[0])
        let buildings = records.compactMap { $0.geometry(projection:projection) }
        for (index,route) in routes.enumerated() {
            func calculate(_ hour:Int) -> RouteExposure {
                let date = ISO8601DateFormatter().date(from:String(format:"2026-09-25T%02d:00:00+04:00",hour))!
                return RouteExposureService.calculate(points:route.coordinates.map(projection.geoToLocal),expectedTravelTime:route.travelSeconds,buildings:buildings) { point,seconds in
                    SolarPositionService.position(at:date.addingTimeInterval(seconds),coordinate:projection.localToGeo(point))
                }
            }
            let noon = calculate(12), afternoon = calculate(16)
            XCTAssertGreaterThan(noon.shadeDistance,0); XCTAssertGreaterThan(noon.sunDistance,0)
            XCTAssertGreaterThan(afternoon.shadeDistance,0); XCTAssertGreaterThan(afternoon.sunDistance,0)
            XCTAssertGreaterThan(abs(noon.sunSeconds-afternoon.sunSeconds),10)
            XCTAssertEqual(noon.sunSeconds+noon.shadeSeconds,route.travelSeconds,accuracy:1e-6)
            let changes = zip(noon.samples,afternoon.samples).filter { $0.decision.directSun != $1.decision.directSun }.count
            XCTAssertGreaterThan(changes,5)
            print("REAL ROUTE \(index): noon \(noon.sunSeconds/60) min; 16:00 \(afternoon.sunSeconds/60) min; \(changes) changed samples. Incomplete height model, NOT ground truth.")
        }
    }
    func testTangentAndLowSun() {
        let b = BuildingGeometry(id:"wall",footprint:[.init(x:0,y:0),.init(x:20,y:0),.init(x:20,y:20),.init(x:0,y:20)],heightMeters:20)
        XCTAssertFalse(ShadeEngine().isPointShaded(.init(x:10,y:40),solar:.init(azimuthDegrees:180,elevationDegrees:45),buildings:[b]))
        XCTAssertTrue(ShadeEngine().isPointShaded(.init(x:10,y:200),solar:.init(azimuthDegrees:180,elevationDegrees:0.001),buildings:[b]))
        XCTAssertFalse(ShadeEngine().isPointShaded(.init(x:10,y:400),solar:.init(azimuthDegrees:180,elevationDegrees:0.001),buildings:[b]))
    }
}
