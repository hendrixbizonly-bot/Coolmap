import XCTest
@testable import ShadeCore
final class RouteDisplayTests:XCTestCase {
    func testGroupingPreservesAllEndpointsAndShadeTransitions() {
        let result=RouteExposureService.calculate(points:[.init(x:0,y:0),.init(x:100,y:0)],expectedTravelTime:600,buildings:[]) { point,_ in
            .init(azimuthDegrees:180,elevationDegrees:point.x<50 ? 45 : -10)
        }
        let runs=RouteDisplayRun.make(result.samples)
        XCTAssertEqual(runs.count,2)
        XCTAssertEqual(runs.map(\.kind),[1,0])
        XCTAssertEqual(runs.flatMap { Array($0.points.dropFirst()) },result.samples.map { $0.sample.end })
        XCTAssertEqual(runs.first?.points.first,result.samples.first?.sample.start)
        let displayed=runs.reduce(0.0) { sum,run in sum+zip(run.points,run.points.dropFirst()).reduce(0.0) { $0+($1.1-$1.0).length } }
        XCTAssertEqual(displayed,100,accuracy:1e-8)
    }
    func testSameColorDisjointSamplesRemainSeparate() {
        let a=RouteExposureService.calculate(points:[.init(x:0,y:0),.init(x:10,y:0)],expectedTravelTime:60,buildings:[]) { _,_ in .init(azimuthDegrees:90,elevationDegrees:45) }
        let b=RouteExposureService.calculate(points:[.init(x:50,y:0),.init(x:60,y:0)],expectedTravelTime:60,buildings:[]) { _,_ in .init(azimuthDegrees:90,elevationDegrees:45) }
        XCTAssertEqual(RouteDisplayRun.make(a.samples+b.samples).count,2)
    }
}
