import Foundation
/// Lossless grouping for rendering: every sampled endpoint is retained.
public struct RouteDisplayRun:Sendable {
    public let kind:Int // 0 night, 1 potential sun, 2 known shade
    public var points:[LocalPoint]
    public static func make(_ samples:[ClassifiedSample])->[Self] {
        var runs:[Self]=[]
        for value in samples {
            let kind=value.solar.elevationDegrees<=0 ? 0 : value.decision.directSun ? 1 : 2
            if let last=runs.last,last.kind==kind,last.points.last==value.sample.start {
                runs[runs.count-1].points.append(value.sample.end)
            } else { runs.append(.init(kind:kind,points:[value.sample.start,value.sample.end])) }
        }
        return runs
    }
}
