import Foundation
public enum HeightSource: String, Codable, Sendable { case exact, levelsEstimate, manualPatch, fallback }
public struct BuildingGeometry: Sendable {
    public let id: String
    public let footprint: [LocalPoint]
    public let heightMeters: Double
    public let heightSource: HeightSource
    public init(id: String, footprint: [LocalPoint], heightMeters: Double, heightSource: HeightSource = .exact) {
        self.id = id; self.footprint = footprint; self.heightMeters = heightMeters; self.heightSource = heightSource
    }
}
/// Azimuth clockwise from north: N=0, E=90, S=180, W=270. Elevation above horizon.
public struct SolarPosition: Sendable {
    public let azimuthDegrees: Double
    public let elevationDegrees: Double
    public init(azimuthDegrees: Double, elevationDegrees: Double) { self.azimuthDegrees = azimuthDegrees; self.elevationDegrees = elevationDegrees }
    public var direction: LocalPoint { .init(x: sin(azimuthDegrees * .pi/180), y: cos(azimuthDegrees * .pi/180)) }
}
public struct ShadeDecision: Sendable {
    public let directSun: Bool
    public let reason: String
    public let buildingID: String?
    public let distanceMeters: Double?
    public let buildingHeight: Double?
    public let rayHeight: Double?
}
public struct PreparedBuilding: Sendable {
    let geometry: BuildingGeometry
    let minX: Double, maxX: Double, minY: Double, maxY: Double
    public static func prepare(_ buildings:[BuildingGeometry]) -> [Self] {
        var seen=Set<String>()
        return buildings.compactMap { b in
            guard seen.insert(b.id).inserted, b.heightMeters > 0, b.heightMeters.isFinite, PolygonGeometry.isValid(b.footprint) else { return nil }
            return Self(geometry:b,minX:b.footprint.map(\.x).min()!,maxX:b.footprint.map(\.x).max()!,minY:b.footprint.map(\.y).min()!,maxY:b.footprint.map(\.y).max()!)
        }
    }
}
public struct ShadeEngine: Sendable {
    /// Explicit bounded coverage policy for low sun; no division by tan near horizon.
    public let maximumSearchDistance: Double
    public init(maximumSearchDistance: Double = 300) { self.maximumSearchDistance = maximumSearchDistance }
    public func isPointShaded(_ point: LocalPoint, solar: SolarPosition, buildings: [BuildingGeometry]) -> Bool {
        !classify(point, solar: solar, buildings: buildings).directSun
    }
    public func classify(_ point: LocalPoint, solar: SolarPosition, buildings: [BuildingGeometry]) -> ShadeDecision {
        classify(point,solar:solar,prepared:PreparedBuilding.prepare(buildings))
    }
    public func classify(_ point:LocalPoint,solar:SolarPosition,prepared:[PreparedBuilding]) -> ShadeDecision {
        if solar.elevationDegrees <= 0 { return .init(directSun: false, reason: "Night: sun below horizon", buildingID: nil, distanceMeters: nil, buildingHeight: nil, rayHeight: nil) }
        let direction = solar.direction
        let end = point + direction * maximumSearchDistance
        var hits: [(BuildingGeometry, Double)] = []
        for item in prepared {
            let b=item.geometry
            guard item.maxX >= min(point.x,end.x), item.minX <= max(point.x,end.x), item.maxY >= min(point.y,end.y), item.minY <= max(point.y,end.y) else { continue }
            if let d = RayIntersection.polygon(origin: point, direction: direction, vertices: b.footprint), d <= maximumSearchDistance { hits.append((b,d)) }
        }
        for (b,d) in hits.sorted(by: { $0.1 < $1.1 }) {
            let rayHeight = d * tan(solar.elevationDegrees * .pi/180)
            if b.heightMeters > rayHeight + 1e-8 {
                return .init(directSun: false, reason: d == 0 ? "Inside/on footprint: inspect route/data" : "Building blocks line of sight", buildingID: b.id, distanceMeters: d, buildingHeight: b.heightMeters, rayHeight: rayHeight)
            }
        }
        return .init(directSun: true, reason: "No blocker within \(Int(maximumSearchDistance)) m; coverage-limited", buildingID: nil, distanceMeters: nil, buildingHeight: nil, rayHeight: nil)
    }
    public func shadowQuads(building: BuildingGeometry, solar: SolarPosition) -> [[LocalPoint]] {
        guard solar.elevationDegrees > 0 else { return [] }
        let offset = solar.direction * -min(maximumSearchDistance, building.heightMeters/tan(solar.elevationDegrees * .pi/180))
        return building.footprint.indices.map { i in
            let a = building.footprint[i], b = building.footprint[(i+1)%building.footprint.count]
            return [a,b,b+offset,a+offset]
        }
    }
}
