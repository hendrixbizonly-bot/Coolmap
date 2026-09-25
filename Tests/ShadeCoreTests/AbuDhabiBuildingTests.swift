import XCTest
@testable import ShadeCore
final class AbuDhabiBuildingTests: XCTestCase {
    func testBundledBuildingsHaveHeightsAndValidPolygons() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("CoolMap/Resources/abudhabi-buildings.json"))
        let records = try JSONDecoder().decode([BuildingRecord].self,from:data)
        XCTAssertFalse(records.isEmpty)
        XCTAssertLessThanOrEqual(data.count,15_000_000)
        XCTAssertEqual(Set(records.map(\.id)).count,records.count)
        let projection = CoordinateProjection(origin:.init(latitude:24.47,longitude:54.36))
        for record in records {
            let height = try XCTUnwrap(record.heightMeters,record.id)
            XCTAssertTrue(height.isFinite && height > 0,record.id)
            XCTAssertTrue([HeightSource.exact,.levelsEstimate,.model].contains(try XCTUnwrap(record.heightSource)),record.id)
            XCTAssertTrue(PolygonGeometry.isValid(record.footprint.map(projection.geoToLocal)),record.id)
            XCTAssertNotNil(record.geometry(projection:projection),record.id)
            XCTAssertTrue(record.footprint.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite && (24.40...24.54).contains($0.latitude) && (54.29...54.43).contains($0.longitude) },record.id)
        }
        XCTAssertTrue(records.contains { $0.heightSource == .model })
        XCTAssertTrue(records.contains { $0.heightSource == .exact && ($0.heightMeters ?? 0) >= 150 && !($0.name ?? "").isEmpty })
    }
}
