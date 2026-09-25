import XCTest
@testable import ShadeCore
final class CityAndNavigationTests:XCTestCase {
    func testTilePlanCoversLongSegmentsAndBuffer() {
        let route=[GeoPoint(latitude:25.20,longitude:55.25),GeoPoint(latitude:25.20,longitude:55.30)]
        let tiles=BuildingTile.covering(routes:[route],bufferMeters:300)
        for longitude in stride(from:55.25,through:55.30,by:0.001) {
            XCTAssertTrue(tiles.contains { $0.x==Int(floor(longitude/0.01)) && $0.y==2520 })
        }
        XCTAssertTrue(tiles.contains { $0.y==2519 }); XCTAssertLessThan(tiles.count,30)
    }
    func testOSMHeightParsingAndUnknownPreservation() throws {
        let xml="""
        <osm><node id="1" lat="25.2" lon="55.2"/><node id="2" lat="25.2" lon="55.201"/><node id="3" lat="25.201" lon="55.201"/>
        <way id="10"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="1"/><tag k="building" v="yes"/><tag k="height" v="50 ft"/></way>
        <way id="11"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="1"/><tag k="building" v="yes"/><tag k="building:levels" v="3"/></way>
        <way id="12"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="1"/><tag k="building" v="yes"/></way></osm>
        """
        let result=try OSMBuildingParser.parse(Data(xml.utf8))
        XCTAssertEqual(result.count,3)
        XCTAssertEqual(result[0].heightMeters!,15.24,accuracy:1e-6)
        XCTAssertEqual(result[1].heightMeters!,9.6,accuracy:1e-6)
        XCTAssertEqual(result[1].heightSource,.levelsEstimate)
        XCTAssertNil(result[2].heightMeters)
    }
    func testIncompleteAndComplexBuildingsAreNotFilled() throws {
        let xml="""
        <osm><node id="1" lat="25.2" lon="55.2"/><node id="2" lat="25.2" lon="55.201"/><node id="3" lat="25.201" lon="55.201"/>
        <way id="10"><nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="1"/><tag k="building" v="yes"/></way>
        <way id="11"><nd ref="1"/><nd ref="999"/><nd ref="3"/><nd ref="1"/><tag k="building" v="yes"/></way>
        <relation id="20"><member type="way" ref="10" role="outer"/><tag k="building" v="yes"/><tag k="type" v="multipolygon"/></relation></osm>
        """
        XCTAssertTrue(try OSMBuildingParser.parse(Data(xml.utf8)).isEmpty)
    }
    func testProgressAndOffRouteDistance() {
        let route=[LocalPoint(x:0,y:0),LocalPoint(x:100,y:0),LocalPoint(x:100,y:100)]
        let result=WalkingProgress.calculate(point:.init(x:100,y:50),route:route,expectedSeconds:200)!
        XCTAssertEqual(result.distanceFromStart,150,accuracy:1e-6)
        XCTAssertEqual(result.remainingDistance,50,accuracy:1e-6)
        XCTAssertEqual(result.remainingSeconds,50,accuracy:1e-6)
        XCTAssertEqual(result.distanceOffRoute,0,accuracy:1e-6)
        let off=WalkingProgress.calculate(point:.init(x:160,y:50),route:route,expectedSeconds:200)!
        XCTAssertEqual(off.distanceOffRoute,60,accuracy:1e-6)
        XCTAssertNil(WalkingProgress.calculate(point:.init(x:0,y:0),route:[],expectedSeconds:100))
    }
    func testGooglePolylineReference() {
        let points=EncodedPolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(points.count,3)
        XCTAssertEqual(points[0].latitude,38.5,accuracy:1e-6)
        XCTAssertEqual(points[2].longitude,-126.453,accuracy:1e-6)
        XCTAssertTrue(EncodedPolyline.decode("~").isEmpty)
    }
}
