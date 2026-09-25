import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct BuildingTile: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public static let size = 0.01
    public var key: String { "\(x)_\(y)" }
    public var bbox: String { "\(Double(x)*Self.size),\(Double(y)*Self.size),\(Double(x+1)*Self.size),\(Double(y+1)*Self.size)" }
    public static func covering(routes:[[GeoPoint]], bufferMeters:Double) -> Set<Self> {
        var result = Set<Self>()
        for route in routes {
            guard let origin = route.first else { continue }
            let projection = CoordinateProjection(origin:origin)
            let points = route.map(projection.geoToLocal)
            let samples = RouteExposureService.sample(points,spacing:200)
            let coordinates = route + samples.map { projection.localToGeo($0.point) }
            // Half a sampling interval pads the requested corridor between samples.
            for p in coordinates {
                let dy = (bufferMeters+100)/111_000
                let dx = dy/max(0.1,cos(p.latitude * .pi/180))
                for x in Int(floor((p.longitude-dx)/size))...Int(floor((p.longitude+dx)/size)) {
                    for y in Int(floor((p.latitude-dy)/size))...Int(floor((p.latitude+dy)/size)) { result.insert(.init(x:x,y:y)) }
                }
            }
        }
        return result
    }
}
/// Imports closed OSM building ways. Relations/courtyards and raised building parts
/// are explicitly omitted rather than incorrectly modeled as solid ground-level blocks.
public final class OSMBuildingParser: NSObject, XMLParserDelegate {
    private var nodes: [String:GeoPoint] = [:]
    private var ways: [(String,[String],[String:String])] = []
    private var relationWays = Set<String>()
    private var relationMembers: [String] = []
    private var inRelation = false
    private var wayID: String?
    private var refs: [String] = []
    private var tags: [String:String] = [:]
    public static func parse(_ data: Data) throws -> [BuildingRecord] {
        let delegate = OSMBuildingParser(), parser = XMLParser(data:data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return delegate.ways.compactMap { id,refs,tags in
            guard tags["building"] != nil, tags["building"] != "no", !delegate.relationWays.contains(id),
                  refs.count >= 4, refs.first == refs.last, refs.allSatisfy({ delegate.nodes[$0] != nil }),
                  (HeightParser.meters(tags["min_height"]) ?? 0) == 0, (Double(tags["building:min_level"] ?? "0") ?? 0) == 0 else { return nil }
            let height = HeightParser.meters(tags["height"])
            let levels = Double(tags["building:levels"] ?? "")
            let estimate = levels.flatMap { $0.isFinite && $0 > 0 ? $0*3.2 : nil }
            return BuildingRecord(id:"osm-way-"+id,footprint:refs.dropLast().compactMap { delegate.nodes[$0] },heightMeters:height ?? estimate,heightSource:height != nil ? .exact : estimate != nil ? .levelsEstimate : nil,name:tags["name:en"] ?? tags["name"])
        }
    }
    public func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes a:[String:String]) {
        switch elementName {
        case "node":
            if let id=a["id"],let lat=Double(a["lat"] ?? ""),let lon=Double(a["lon"] ?? "") { nodes[id] = .init(latitude:lat,longitude:lon) }
        case "way": wayID=a["id"]; refs=[]; tags=[:]
        case "nd": if let ref=a["ref"], wayID != nil { refs.append(ref) }
        case "relation": inRelation=true; relationMembers=[]; tags=[:]
        case "member": if inRelation, a["type"] == "way", let ref=a["ref"] { relationMembers.append(ref) }
        case "tag": if let k=a["k"],let v=a["v"] { tags[k]=v }
        default: break
        }
    }
    public func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?) {
        if elementName == "way",let id=wayID { ways.append((id,refs,tags)); wayID=nil }
        if elementName == "relation" { if tags["building"] != nil { relationWays.formUnion(relationMembers) }; inRelation=false }
    }
}
