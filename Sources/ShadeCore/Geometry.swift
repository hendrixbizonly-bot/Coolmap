import Foundation

public struct LocalPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static func + (a: Self, b: Self) -> Self { .init(x: a.x+b.x, y: a.y+b.y) }
    public static func - (a: Self, b: Self) -> Self { .init(x: a.x-b.x, y: a.y-b.y) }
    public static func * (a: Self, b: Double) -> Self { .init(x: a.x*b, y: a.y*b) }
    public var length: Double { hypot(x, y) }
}
public struct GeoPoint: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}
/// Small-area flat-earth projection. +x east, +y north. All geometry shares one origin.
public struct CoordinateProjection: Sendable {
    public let origin: GeoPoint
    public init(origin: GeoPoint) { self.origin = origin }
    public func geoToLocal(_ p: GeoPoint) -> LocalPoint {
        .init(x: 6_371_000 * cos(origin.latitude * .pi/180) * (p.longitude-origin.longitude) * .pi/180,
              y: 6_371_000 * (p.latitude-origin.latitude) * .pi/180)
    }
    public func localToGeo(_ p: LocalPoint) -> GeoPoint {
        .init(latitude: origin.latitude+p.y/6_371_000*180 / .pi,
              longitude: origin.longitude+p.x/(6_371_000*cos(origin.latitude * .pi/180))*180 / .pi)
    }
}
public enum RayIntersection {
    static let epsilon = 1e-8
    static func cross(_ a: LocalPoint, _ b: LocalPoint) -> Double { a.x*b.y-a.y*b.x }
    /// Returns ray parameter t. Unit direction makes t a distance in meters.
    public static func segment(origin: LocalPoint, direction: LocalPoint, a: LocalPoint, b: LocalPoint) -> Double? {
        let edge = b-a, offset = a-origin, denominator = cross(direction, edge)
        guard direction.length > epsilon else { return nil }
        if abs(denominator) < epsilon {
            guard abs(cross(offset, direction)) < epsilon else { return nil }
            let norm = direction.x*direction.x+direction.y*direction.y
            let t1 = (offset.x*direction.x+offset.y*direction.y)/norm
            let end = b-origin
            let t2 = (end.x*direction.x+end.y*direction.y)/norm
            guard max(t1,t2) >= -epsilon else { return nil }
            return max(0,min(t1,t2))
        }
        let t = cross(offset,edge)/denominator, u = cross(offset,direction)/denominator
        return t >= -epsilon && u >= -epsilon && u <= 1+epsilon ? max(0,t) : nil
    }
    public static func polygon(origin: LocalPoint, direction: LocalPoint, vertices: [LocalPoint]) -> Double? {
        guard vertices.count >= 3 else { return nil }
        if PolygonGeometry.contains(origin, vertices) { return 0 }
        return vertices.indices.compactMap { segment(origin: origin, direction: direction, a: vertices[$0], b: vertices[($0+1)%vertices.count]) }.min()
    }
}
public enum PolygonGeometry {
    public static func contains(_ p: LocalPoint, _ polygon: [LocalPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i+1)%polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
        }
        return inside
    }
    public static func isValid(_ points: [LocalPoint]) -> Bool {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let area = points.indices.reduce(0.0) { $0 + RayIntersection.cross(points[$1],points[($1+1)%points.count]) }
        guard abs(area) > 1e-6 else { return false }
        for i in points.indices {
            let next = (i+1)%points.count
            let edge = points[next]-points[i]
            guard edge.length > 1e-8 else { return false }
            for j in points.indices where j > i {
                let otherNext = (j+1)%points.count
                if j == next || otherNext == i { continue }
                if let t = RayIntersection.segment(origin:points[i],direction:edge,a:points[j],b:points[otherNext]), t <= 1+1e-8 { return false }
            }
        }
        return true
    }
}
