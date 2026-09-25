import Foundation
import MapKit

struct BuildingLoad: Sendable {
    let records: [BuildingRecord]
    let completeFetch: Bool
    let note: String
}
actor CityBuildingProvider {
    static let shared = CityBuildingProvider()
    private var memory: [String:[BuildingRecord]] = [:]
    private let cache = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("OSMBuildings-v1")
    /// Route-scoped data across Dubai, never a city-wide bulk download.
    func load(routes:[[GeoPoint]],buffer:Double) async -> BuildingLoad {
        let tiles = BuildingTile.covering(routes:routes,bufferMeters:buffer).sorted { $0.key < $1.key }
        guard tiles.count <= 64 else { return .init(records:[],completeFetch:false,note:"This walk is too long for the prototype’s building download limit. Walking directions are still available.") }
        var all: [String:BuildingRecord] = [:]
        do {
            for tile in tiles {
                try Task.checkCancellation()
                for record in try await fetch(tile) { all[record.id] = record }
            }
            // Tiles extend beyond the walk. Keep any footprint whose bounds could
            // intersect its search area, including large buildings crossing the edge.
            let points=routes.flatMap { $0 }
            guard let first=points.first else { return .init(records:[],completeFetch:true,note:"No route geometry") }
            let projection=CoordinateProjection(origin:first)
            let local=points.map(projection.geoToLocal)
            let minX=local.map(\.x).min()!-buffer, maxX=local.map(\.x).max()!+buffer
            let minY=local.map(\.y).min()!-buffer, maxY=local.map(\.y).max()!+buffer
            let relevant=all.values.filter { record in
                let footprint=record.footprint.map(projection.geoToLocal)
                guard let left=footprint.map(\.x).min(),let right=footprint.map(\.x).max(),
                      let bottom=footprint.map(\.y).min(),let top=footprint.map(\.y).max() else { return false }
                return right>=minX && left<=maxX && top>=minY && bottom<=maxY
            }.sorted { $0.id < $1.id }
            return .init(records:relevant,completeFetch:true,note:"OpenStreetMap · \(tiles.count) area tiles · missing heights and complex buildings may be omitted")
        } catch {
            return .init(records:[],completeFetch:false,note:"Building data couldn’t be loaded. Check your connection and retry. Walking directions still work.")
        }
    }
    private func fetch(_ tile:BuildingTile) async throws -> [BuildingRecord] {
        if let stored=memory[tile.key] { return stored }
        let file=cache.appendingPathComponent(tile.key+".json")
        if let attributes=try? FileManager.default.attributesOfItem(atPath:file.path),let modified=attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified)<7*86400,
           let data=try? Data(contentsOf:file),let stored=try? JSONDecoder().decode([BuildingRecord].self,from:data) { memory[tile.key]=stored; return stored }
        var request=URLRequest(url:URL(string:"https://api.openstreetmap.org/api/0.6/map?bbox="+tile.bbox)!)
        request.timeoutInterval=30
        request.setValue("CoolmapPrototype/0.1 (route-scoped building geometry)",forHTTPHeaderField:"User-Agent")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 25_000_000 else { throw URLError(.badServerResponse) }
        let records=try OSMBuildingParser.parse(data)
        try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        try? JSONEncoder().encode(records).write(to:file,options:.atomic)
        memory[tile.key]=records
        return records
    }
}
