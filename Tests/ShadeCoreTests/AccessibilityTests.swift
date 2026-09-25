import XCTest
@testable import ShadeCore
final class AccessibilityTests: XCTestCase {
    private func parse(_ body:String) throws -> [AccessBarrier] {
        try OSMAccessParser.parse(Data(("<osm>"+body+"</osm>").utf8))
    }
    private func barrier(_ barriers:[AccessBarrier],_ id:String) -> AccessBarrier? { barriers.first { $0.id == id } }
    func testParser() throws {
        let xml = """
        <node id="1" lat="25.0" lon="55.0"><tag k="barrier" v="kerb"/><tag k="kerb" v="raised"/></node>
        <node id="2" lat="25.0" lon="55.0001"><tag k="barrier" v="kerb"/><tag k="kerb" v="lowered"/></node>
        <node id="3" lat="25.0" lon="55.0002"><tag k="barrier" v="kerb"/><tag k="wheelchair" v="no"/></node>
        <node id="4" lat="25.0" lon="55.0003"><tag k="highway" v="elevator"/></node>
        <node id="5" lat="25.0" lon="55.0004"><tag k="highway" v="elevator"/><tag k="wheelchair" v="no"/></node>
        <node id="6" lat="25.0" lon="55.0005"><tag k="wheelchair" v="no"/></node>
        <node id="10" lat="25.0" lon="55.0"/><node id="11" lat="25.001" lon="55.0"/>
        <node id="12" lat="25.0" lon="55.001"/><node id="13" lat="25.001" lon="55.001"/>
        <node id="14" lat="25.0" lon="55.002"/><node id="15" lat="25.001" lon="55.002"/>
        <node id="16" lat="25.0" lon="55.003"/><node id="17" lat="25.001" lon="55.003"/>
        <node id="18" lat="25.0" lon="55.004"/><node id="19" lat="25.001" lon="55.004"/>
        <way id="100"><nd ref="10"/><nd ref="11"/><tag k="highway" v="steps"/><tag k="step_count" v="14"/></way>
        <way id="101"><nd ref="12"/><nd ref="13"/><tag k="highway" v="steps"/><tag k="ramp:wheelchair" v="yes"/></way>
        <way id="102"><nd ref="14"/><nd ref="15"/><tag k="highway" v="footway"/><tag k="incline" v="12%"/></way>
        <way id="103"><nd ref="16"/><nd ref="17"/><tag k="highway" v="footway"/><tag k="incline" v="5%"/></way>
        <way id="104"><nd ref="18"/><nd ref="19"/><tag k="highway" v="footway"/><tag k="surface" v="cobblestone"/></way>
        """
        let b = try parse(xml)
        XCTAssertEqual(barrier(b,"osm-way-100")?.kind,.steps)
        XCTAssertEqual(barrier(b,"osm-way-100")?.detail,"Steps · 14 steps")
        XCTAssertEqual(barrier(b,"osm-way-100")?.blocking,true)
        XCTAssertNil(barrier(b,"osm-way-101"))
        XCTAssertEqual(barrier(b,"osm-way-102")?.kind,.steepIncline)
        XCTAssertEqual(barrier(b,"osm-way-102")?.blocking,false)
        XCTAssertEqual(barrier(b,"osm-way-102")?.detail,"Incline 12%")
        XCTAssertNil(barrier(b,"osm-way-103"))
        XCTAssertEqual(barrier(b,"osm-way-104")?.kind,.roughSurface)
        XCTAssertEqual(barrier(b,"osm-way-104")?.detail,"Surface: cobblestone")
        XCTAssertEqual(barrier(b,"osm-node-1")?.kind,.raisedKerb)
        XCTAssertEqual(barrier(b,"osm-node-1")?.blocking,true)
        XCTAssertNil(barrier(b,"osm-node-2"))
        XCTAssertEqual(barrier(b,"osm-node-3")?.kind,.raisedKerb)
        XCTAssertEqual(barrier(b,"osm-node-4")?.kind,.elevator)
        XCTAssertEqual(barrier(b,"osm-node-4")?.blocking,false)
        XCTAssertEqual(barrier(b,"osm-node-5")?.kind,.elevator)
        XCTAssertEqual(barrier(b,"osm-node-5")?.blocking,true)
        XCTAssertEqual(barrier(b,"osm-node-6")?.kind,.noWheelchair)
        XCTAssertEqual(b.count,8)
    }
    func testInclineParsing() throws {
        let nodes = (20...21).map { "<node id=\"\($0)\" lat=\"25.0\(($0-20))\" lon=\"55.0\"/>" }.joined()
        func way(_ id:Int,_ incline:String) -> String {
            "<way id=\"\(id)\"><nd ref=\"20\"/><nd ref=\"21\"/><tag k=\"highway\" v=\"footway\"/><tag k=\"incline\" v=\"\(incline)\"/></way>"
        }
        let b = try parse(nodes+way(200,"1:10")+way(201,"0.05")+way(202,"steep")+way(203,"up")+way(204,"0.15"))
        XCTAssertEqual(barrier(b,"osm-way-200")?.kind,.steepIncline)
        XCTAssertNil(barrier(b,"osm-way-201"))
        XCTAssertEqual(barrier(b,"osm-way-202")?.kind,.steepIncline)
        XCTAssertNil(barrier(b,"osm-way-203"))
        XCTAssertEqual(barrier(b,"osm-way-204")?.kind,.steepIncline)
        XCTAssertEqual(OSMAccessParser.inclinePercent("1:10"),10)
        XCTAssertEqual(OSMAccessParser.inclinePercent("-8.3%"),8.3)
    }
    private func geoRoute(_ metres:Double,from origin:GeoPoint = .init(latitude:25.0,longitude:55.0)) -> [GeoPoint] {
        let p = CoordinateProjection(origin:origin)
        return [p.localToGeo(.init(x:0,y:0)),p.localToGeo(.init(x:metres,y:0))]
    }
    func testAssess() {
        let origin = GeoPoint(latitude:25.0,longitude:55.0)
        let p = CoordinateProjection(origin:origin)
        let route = geoRoute(200,from:origin)
        func steps(northOf metres:Double) -> AccessBarrier {
            AccessBarrier(id:"steps-\(metres)",kind:.steps,points:[p.localToGeo(.init(x:100,y:metres-5)),p.localToGeo(.init(x:100,y:metres+5))],detail:"Steps, no ramp",blocking:true)
        }
        XCTAssertFalse(StepFreeAssessment.assess(route:route,barriers:[steps(northOf:5)]).isStepFree)
        XCTAssertTrue(StepFreeAssessment.assess(route:route,barriers:[steps(northOf:40)]).isStepFree)
        let steep = AccessBarrier(id:"slope",kind:.steepIncline,points:[p.localToGeo(.init(x:50,y:2)),p.localToGeo(.init(x:150,y:2))],detail:"Incline 12%",blocking:false)
        let result = StepFreeAssessment.assess(route:route,barriers:[steep])
        XCTAssertTrue(result.isStepFree)
        XCTAssertEqual(result.penaltySeconds,120)
        XCTAssertEqual(result.adjustedSeconds(expected:600),600*RouteAccessibility.paceFactor+120)
    }
}
