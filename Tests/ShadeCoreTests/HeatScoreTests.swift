import XCTest
@testable import ShadeCore
final class HeatScoreTests: XCTestCase {
    func exposure(length: Double = 100, time: Double = 600, elevation: Double = 30, buildings: [BuildingGeometry] = []) -> RouteExposure {
        RouteExposureService.calculate(points:[.init(x:0,y:0),.init(x:length,y:0)],expectedTravelTime:time,buildings:buildings) { _,_ in
            SolarPosition(azimuthDegrees:180,elevationDegrees:elevation)
        }
    }
    func test1ReferenceWeights() {
        let elevations = [10.0,20,30,45,60,75,85], expected = [0.64,0.92,1,0.94,0.78,0.56,0.43]
        for (h,w) in zip(elevations,expected) {
            XCTAssertEqual(SunIntensity.weight(elevationDegrees:h),w,accuracy:0.03)
        }
    }
    func test2BoundsAndPeak() {
        for h in [-20.0,0] { XCTAssertEqual(SunIntensity.weight(elevationDegrees:h),0) }
        XCTAssertEqual(SunIntensity.weight(elevationDegrees:32.41483),1,accuracy:1e-9)
        XCTAssertEqual(SunIntensity.weight(elevationDegrees:.nan),0)
        for h in stride(from:1.0,through:90,by:1) {
            let w = SunIntensity.weight(elevationDegrees:h)
            XCTAssertGreaterThanOrEqual(w,0); XCTAssertLessThanOrEqual(w,1)
        }
    }
    func test3AllShade() {
        let block = BuildingGeometry(id:"block",footprint:[.init(x:-10,y:-10),.init(x:110,y:-10),.init(x:110,y:10),.init(x:-10,y:10)],heightMeters:20)
        let e = exposure(buildings:[block])
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600),600,accuracy:1e-8)
        XCTAssertTrue(e.samples.allSatisfy { $0.decision.sunFraction == 0 })
    }
    func test4FullSun() {
        let e = exposure()
        let w30 = SunIntensity.weight(elevationDegrees:30)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600),600*(1+RouteHeat.defaultK*w30),accuracy:1e-8)
        XCTAssertTrue(e.samples.allSatisfy { $0.decision.sunFraction == 1 })
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600,k:0),600,accuracy:1e-8)
    }
    func test5FromDistanceClipsPartialIntervals() {
        let e = exposure()
        let full = RouteHeat.cost(e,expectedTravelTime:600)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600,fromDistance:50),full/2,accuracy:1e-8)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600,fromDistance:100),0)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600,fromDistance:101),0)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:600,fromDistance:-10),full,accuracy:1e-8)
    }
    func test6DegenerateInputs() {
        let empty = RouteExposureService.calculate(points:[],expectedTravelTime:600,buildings:[]) { _,_ in .init(azimuthDegrees:180,elevationDegrees:30) }
        XCTAssertEqual(RouteHeat.cost(empty,expectedTravelTime:600),0)
        XCTAssertEqual(RouteHeat.cost(exposure(),expectedTravelTime:0),0)
        XCTAssertEqual(RouteHeat.cost(exposure(elevation:-5),expectedTravelTime:600),600,accuracy:1e-8)
    }
    func test7UnevenSampleWeighting() {
        let e = RouteExposureService.calculate(points:[.init(x:0,y:0),.init(x:1,y:0),.init(x:10,y:0)],expectedTravelTime:100,buildings:[]) { point,_ in
            .init(azimuthDegrees:180,elevationDegrees:point.x<1 ? 10 : 60)
        }
        let k = RouteHeat.defaultK, w10 = SunIntensity.weight(elevationDegrees:10), w60 = SunIntensity.weight(elevationDegrees:60)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:100),100*(1+k*(0.1*w10+0.9*w60)),accuracy:1e-8)
        XCTAssertEqual(RouteHeat.cost(e,expectedTravelTime:100,fromDistance:0.5),5*(1+k*w10)+90*(1+k*w60),accuracy:1e-8)
    }
    func test8LongerShadedRouteBeatsSunnyRoute() {
        let block = BuildingGeometry(id:"block",footprint:[.init(x:-10,y:-10),.init(x:110,y:-10),.init(x:110,y:10),.init(x:-10,y:10)],heightMeters:20)
        let shade = RouteHeat.cost(exposure(buildings:[block]),expectedTravelTime:700)
        let sun = RouteHeat.cost(exposure(),expectedTravelTime:600)
        XCTAssertLessThan(shade,sun)
    }
}
