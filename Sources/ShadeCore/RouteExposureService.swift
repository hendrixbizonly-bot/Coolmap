import Foundation
public struct RouteSample: Sendable {
    public let start: LocalPoint
    public let end: LocalPoint
    public let point: LocalPoint
    public let distanceFromPreviousSample: Double
    public let distanceFromStart: Double
}
public struct ClassifiedSample: Sendable {
    public let sample: RouteSample
    public let solar: SolarPosition
    public let decision: ShadeDecision
}
public struct RouteExposure: Sendable {
    public let samples: [ClassifiedSample]
    public let sunDistance: Double
    public let shadeDistance: Double
    public let sunSeconds: Double
    public let shadeSeconds: Double
}
public enum RouteExposureService {
    /// Each midpoint represents its own interval. Short final intervals retain their actual weight.
    public static func sample(_ points: [LocalPoint], spacing: Double = 4) -> [RouteSample] {
        guard points.count >= 2, spacing.isFinite, spacing > 0 else { return [] }
        var result: [RouteSample] = [], cumulative = 0.0
        for i in 1..<points.count {
            let a = points[i-1], delta = points[i]-a, length = delta.length
            guard length.isFinite, length > 0 else { continue }
            let count = Int(ceil(length/spacing))
            for j in 0..<count {
                let start = a + delta * (Double(j)/Double(count))
                let end = a + delta * (Double(j+1)/Double(count))
                let distance = length/Double(count)
                result.append(.init(start:start,end:end,point:(start+end)*0.5,distanceFromPreviousSample:distance,distanceFromStart:cumulative+distance*0.5))
                cumulative += distance
            }
        }
        return result
    }
    public static func calculate(points: [LocalPoint], expectedTravelTime: Double, buildings: [BuildingGeometry], engine: ShadeEngine = .init(), solarAt: (LocalPoint, Double) -> SolarPosition) -> RouteExposure {
        let samples = sample(points), total = samples.reduce(0) { $0+$1.distanceFromPreviousSample }
        let prepared = PreparedBuilding.prepare(buildings)
        let classified = samples.map { sample in
            let seconds = total > 0 ? expectedTravelTime*sample.distanceFromStart/total : 0
            let solar = solarAt(sample.point,seconds)
            return ClassifiedSample(sample:sample,solar:solar,decision:engine.classify(sample.point,solar:solar,prepared:prepared))
        }
        let sun = classified.filter { $0.decision.directSun }.reduce(0) { $0+$1.sample.distanceFromPreviousSample }
        let sunSeconds = total > 0 ? max(0,expectedTravelTime)*sun/total : 0
        return .init(samples:classified,sunDistance:sun,shadeDistance:total-sun,sunSeconds:sunSeconds,shadeSeconds:total > 0 ? max(0,expectedTravelTime)-sunSeconds : 0)
    }
}
