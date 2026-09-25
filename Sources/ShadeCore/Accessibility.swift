import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct AccessBarrier: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case steps, raisedKerb, steepIncline, roughSurface, noWheelchair, elevator }
    public let id: String            // "osm-node-123" / "osm-way-456" / "report-<uuid>"
    public let kind: Kind
    public let points: [GeoPoint]    // 1 point for nodes, the way geometry for ways
    public let detail: String
    /// True when a wheelchair/stroller cannot pass (steps w/o ramp, raised kerb, wheelchair=no, broken elevator report).
    /// False for slow-downs (steep incline, rough surface). `elevator` is informational (blocking=false) unless reported broken.
    public let blocking: Bool
    public init(id: String, kind: Kind, points: [GeoPoint], detail: String, blocking: Bool) {
        self.id = id; self.kind = kind; self.points = points; self.detail = detail; self.blocking = blocking
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Imports OSM features that block or slow wheelchairs and strollers.
public final class OSMAccessParser: NSObject, XMLParserDelegate {
    /// Roughly the 1:12 maximum running slope of an accessible route.
    public static let maxInclinePercent = 8.3
    private static let roughSurfaces: Set<String> = ["cobblestone","sett","unhewn_cobblestone","gravel","fine_gravel","pebblestone","ground","dirt","earth","mud","sand","grass","unpaved","woodchips"]
    private var nodes: [String:GeoPoint] = [:]
    private var nodeTags: [String:[String:String]] = [:]
    private var ways: [(String,[String],[String:String])] = []
    private var nodeID: String?
    private var wayID: String?
    private var refs: [String] = []
    private var tags: [String:String] = [:]
    private static func tag(_ tags:[String:String],_ key:String) -> String? {
        tags[key]?.trimmingCharacters(in:.whitespaces).lowercased()
    }
    /// Incline tag to percent: "12%", "-8.3%", "1:10", "0.15", "steep"; "up"/"down" are unknown.
    static func inclinePercent(_ raw:String) -> Double? {
        let value = raw.trimmingCharacters(in:.whitespaces).lowercased()
        if value == "steep" { return 15 }
        if value.hasSuffix("%"), let n = Double(value.dropLast()) { return abs(n) }
        if let colon = value.firstIndex(of:":"), let rise = Double(value[..<colon]), let run = Double(value[value.index(after:colon)...]), rise != 0, run != 0 { return abs(rise/run)*100 }
        if let n = Double(value) { let n = abs(n); return n <= 1 ? n*100 : n }
        return nil
    }
    public static func parse(_ data: Data) throws -> [AccessBarrier] {
        let delegate = OSMAccessParser(), parser = XMLParser(data:data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        var barriers: [AccessBarrier] = []
        for (id,tags) in delegate.nodeTags {
            guard let point = delegate.nodes[id] else { continue }
            if let barrier = nodeBarrier(id:id,tags:tags,point:point) { barriers.append(barrier) }
        }
        for (id,refs,tags) in delegate.ways {
            let points = refs.compactMap { delegate.nodes[$0] }
            guard points.count >= 2 else { continue }
            if let barrier = wayBarrier(id:id,tags:tags,points:points) { barriers.append(barrier) }
        }
        return barriers
    }
    private static func nodeBarrier(id:String,tags:[String:String],point:GeoPoint) -> AccessBarrier? {
        if tag(tags,"highway") == "elevator" {
            let blocked = tag(tags,"wheelchair") == "no"
            return AccessBarrier(id:"osm-node-"+id,kind:.elevator,points:[point],detail:blocked ? "Elevator, not wheelchair accessible" : "Elevator",blocking:blocked)
        }
        if tag(tags,"barrier") == "kerb" {
            let kerb = tag(tags,"kerb")
            if kerb == "flush" || kerb == "lowered" { return nil }
            if kerb == "raised" || (kerb == nil && tag(tags,"wheelchair") == "no") {
                return AccessBarrier(id:"osm-node-"+id,kind:.raisedKerb,points:[point],detail:"Raised kerb",blocking:true)
            }
        }
        if tag(tags,"wheelchair") == "no" {
            return AccessBarrier(id:"osm-node-"+id,kind:.noWheelchair,points:[point],detail:"Not wheelchair accessible",blocking:true)
        }
        return nil
    }
    private static func wayBarrier(id:String,tags:[String:String],points:[GeoPoint]) -> AccessBarrier? {
        let wayID = "osm-way-"+id
        if tag(tags,"highway") == "steps" {
            if tag(tags,"ramp") == "yes" || tag(tags,"ramp:wheelchair") == "yes" || tag(tags,"ramp:stroller") == "yes" || tag(tags,"wheelchair") == "yes" { return nil }
            let detail = tags["step_count"].flatMap(Int.init).map { "Steps · \($0) steps" } ?? "Steps, no ramp"
            return AccessBarrier(id:wayID,kind:.steps,points:points,detail:detail,blocking:true)
        }
        guard tag(tags,"highway") != nil || tag(tags,"footway") != nil else { return nil }
        if tag(tags,"wheelchair") == "no" {
            return AccessBarrier(id:wayID,kind:.noWheelchair,points:points,detail:"Not wheelchair accessible",blocking:true)
        }
        if let raw = tags["incline"], let percent = inclinePercent(raw), percent > maxInclinePercent {
            let text = percent == percent.rounded() ? "\(Int(percent))" : String(format:"%.1f",percent)
            return AccessBarrier(id:wayID,kind:.steepIncline,points:points,detail:"Incline \(text)%",blocking:false)
        }
        if let surface = tag(tags,"surface"), roughSurfaces.contains(surface) {
            return AccessBarrier(id:wayID,kind:.roughSurface,points:points,detail:"Surface: \(surface)",blocking:false)
        }
        return nil
    }
    public func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes a:[String:String]) {
        switch elementName {
        case "node":
            nodeID=a["id"]; tags=[:]
            if let id=nodeID,let lat=Double(a["lat"] ?? ""),let lon=Double(a["lon"] ?? "") { nodes[id] = .init(latitude:lat,longitude:lon) }
        case "way": wayID=a["id"]; refs=[]; tags=[:]
        case "nd": if let ref=a["ref"], wayID != nil { refs.append(ref) }
        case "tag": if let k=a["k"],let v=a["v"] { tags[k]=v }
        default: break
        }
    }
    public func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?) {
        if elementName == "node",let id=nodeID { if !tags.isEmpty { nodeTags[id]=tags }; nodeID=nil; tags=[:] }
        if elementName == "way",let id=wayID { ways.append((id,refs,tags)); wayID=nil }
    }
}

public struct RouteAccessibility: Sendable {
    public let barriers: [AccessBarrier]  // those within the corridor, blocking first, deduped by id
    public var blocking: [AccessBarrier] { barriers.filter(\.blocking) }
    public var isStepFree: Bool { blocking.isEmpty }
    public let penaltySeconds: Double      // 120 per steepIncline, 60 per roughSurface, 0 for elevator (not broken)
    /// Wheelchair/stroller pace: expected * paceFactor + penalty
    public static let paceFactor = 1.35
    public func adjustedSeconds(expected: Double) -> Double { expected*Self.paceFactor + penaltySeconds }
    public init(barriers: [AccessBarrier]) {
        var seen = Set<String>()
        self.barriers = barriers.filter { seen.insert($0.id).inserted }.sorted { $0.blocking && !$1.blocking }
        penaltySeconds = self.barriers.reduce(0) { $0 + ($1.kind == .steepIncline ? 120 : $1.kind == .roughSurface ? 60 : 0) }
    }
}
public enum StepFreeAssessment {
    public static let corridorMeters = 12.0
    private static func distance(_ p:LocalPoint,toSegment a:LocalPoint,_ b:LocalPoint) -> Double {
        let edge = b-a, length = edge.length
        guard length > 0 else { return (p-a).length }
        let t = min(1,max(0,((p.x-a.x)*edge.x+(p.y-a.y)*edge.y)/(length*length)))
        return (p-(a+edge*t)).length
    }
    private static func distance(_ p:LocalPoint,toPolyline line:[LocalPoint]) -> Double {
        var best = Double.infinity
        for i in 1..<line.count { best = min(best,distance(p,toSegment:line[i-1],line[i])) }
        return best
    }
    /// A barrier is "on" the route if any of its points is within corridorMeters of the polyline
    /// (point-to-segment distance; for way barriers also check each route vertex against the barrier's segments).
    public static func assess(route:[GeoPoint], barriers:[AccessBarrier]) -> RouteAccessibility {
        guard let origin = route.first else { return RouteAccessibility(barriers:[]) }
        let projection = CoordinateProjection(origin:origin)
        let line = route.map(projection.geoToLocal)
        let matched = barriers.filter { barrier in
            let points = barrier.points.map(projection.geoToLocal)
            if points.contains(where: { distance($0,toPolyline:line) <= corridorMeters }) { return true }
            if points.count >= 2 { return line.contains(where: { distance($0,toPolyline:points) <= corridorMeters }) }
            return false
        }
        return RouteAccessibility(barriers:matched)
    }
}
