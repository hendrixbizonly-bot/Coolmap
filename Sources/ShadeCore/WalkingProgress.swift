import Foundation
public struct WalkingProgress: Sendable {
    /// Follow only fixes near this walk, never a simulator default in another city.
    public var canFollowLocation:Bool { distanceOffRoute.isFinite && distanceOffRoute <= 250 }
    public let distanceFromStart: Double
    public let remainingDistance: Double
    public let distanceOffRoute: Double
    public let remainingSeconds: Double
    public static func calculate(point:LocalPoint,route:[LocalPoint],expectedSeconds:Double) -> Self? {
        guard route.count>=2 else { return nil }
        var nearest=Double.infinity, at=0.0, cumulative=0.0
        for i in 1..<route.count {
            let a=route[i-1], edge=route[i]-a, length=edge.length
            guard length>0 else { continue }
            let relative=point-a
            let t=min(1,max(0,(relative.x*edge.x+relative.y*edge.y)/(length*length)))
            let distance=(point-(a+edge*t)).length
            if distance<nearest { nearest=distance; at=cumulative+t*length }
            cumulative+=length
        }
        guard cumulative>0 else { return nil }
        return .init(distanceFromStart:at,remainingDistance:cumulative-at,distanceOffRoute:nearest,remainingSeconds:expectedSeconds*(cumulative-at)/cumulative)
    }
}
