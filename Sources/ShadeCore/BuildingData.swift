import Foundation
public enum HeightParser {
    public static func meters(_ text: String?) -> Double? {
        guard let text else { return nil }
        let value = text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        let suffixes = [("meters",1.0),("metres",1.0),(" ft",0.3048),("ft",0.3048),(" m",1.0),("m",1.0),("'",0.3048)]
        for (suffix,factor) in suffixes where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count).trimmingCharacters(in:.whitespaces)), number > 0, number.isFinite else { return nil }
            return number*factor
        }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }
}
public struct BuildingRecord: Codable, Sendable {
    public let id: String
    public let footprint: [GeoPoint]
    public let heightMeters: Double?
    public let heightSource: HeightSource?
    public let name: String?
    public func geometry(projection: CoordinateProjection) -> BuildingGeometry? {
        guard let heightMeters, let heightSource else { return nil }
        let points = footprint.map(projection.geoToLocal)
        guard PolygonGeometry.isValid(points) else { return nil }
        return .init(id:id,footprint:points,heightMeters:heightMeters,heightSource:heightSource)
    }
}
