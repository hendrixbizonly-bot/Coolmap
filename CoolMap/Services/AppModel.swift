import SwiftUI
import MapKit
import Combine
@MainActor
final class AppModel: ObservableObject {
    @Published var origin = CLLocationCoordinate2D(latitude:25.0777,longitude:55.1400)
    @Published var destination = CLLocationCoordinate2D(latitude:25.0794,longitude:55.1413)
    @Published var originName = "Marina Mall promenade"
    @Published var destinationName = "Marina promenade · north"
    @Published var routes: [RouteOption] = []
    @Published var records: [BuildingRecord] = [] {
        didSet {
            cachedBuildings=records.compactMap { $0.geometry(projection:projection) }
            recordsRevision=UUID()
        }
    }
    private var cachedBuildings:[BuildingGeometry]=[]
    private(set) var recordsRevision=UUID()
    @Published private(set) var exposureRevision=0
    @Published var selected = 0
    @Published var busy = false
    @Published var status = "Dubai Marina demo · load walking routes"
    @Published var departure = Date()
    @Published var debug = false
    @Published var shadows = false
    @Published var buffer = 300.0
    @Published var selectedSample: Int?
    @Published var hasOrigin = false
    @Published var hasDestination = false
    @Published var usesCurrentLocation = true
    @Published var loadingBuildings = false
    @Published var calculating = false
    @Published var dataNote = ""
    private var exposureTask: Task<Void,Never>?
    private var requestID = UUID()
    func invalidate() {
        exposureTask?.cancel(); loadingBuildings = false; calculating = false; requestID = UUID(); busy = false; routes = []; records = []; selectedSample = nil; status = ""
    }
    func chooseOrigin(_ coordinate: CLLocationCoordinate2D, name: String, current: Bool = false) {
        invalidate(); origin = coordinate; originName = name; hasOrigin = true; usesCurrentLocation = current
    }
    func chooseDestination(_ coordinate: CLLocationCoordinate2D, name: String) {
        invalidate(); destination = coordinate; destinationName = name; hasDestination = true
    }
    func demo() async {
        chooseOrigin(.init(latitude:25.0777,longitude:55.1400),name:"Marina Mall promenade")
        chooseDestination(.init(latitude:25.0794,longitude:55.1413),name:"Marina promenade · north")
        setHour(16); await load()
    }
    static func inCoverage(_ p: CLLocationCoordinate2D) -> Bool {
        p.latitude >= 25.073 && p.latitude <= 25.085 && p.longitude >= 55.132 && p.longitude <= 55.145
    }
    var projection: CoordinateProjection { .init(origin:origin.geo) }
    var buildings: [BuildingGeometry] { cachedBuildings }
    var solar: SolarPosition { SolarPositionService.position(at:departure,coordinate:origin.geo) }
    var active: RouteOption? { routes.indices.contains(selected) ? routes[selected] : nil }
    var hasUnknownHeights: Bool { cachedBuildings.count != records.count }
    var fastest: UUID? { routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime })?.id }
    var bestShade: UUID? {
        guard routes.count > 1, !hasUnknownHeights, routes.allSatisfy({ $0.exposure != nil }) else { return nil }
        return routes.min(by: { $0.exposure!.sunSeconds < $1.exposure!.sunSeconds })?.id
    }
    func setHour(_ hour:Int) {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"Asia/Dubai")!
        departure = calendar.date(bySettingHour:hour,minute:0,second:0,of:departure)!
        recalculate()
    }
    func load() async {
        guard hasOrigin && hasDestination else { return }
        let token = UUID(); requestID = token; busy = true
        defer { if requestID == token { busy = false } }
        exposureTask?.cancel(); calculating=false; loadingBuildings=false
        routes = []; records = []; selectedSample = nil; status = ""
        let start = origin, finish = destination
        do {
            let candidates = try await DirectionsService().routes(from:start,to:finish)
            guard requestID == token else { return }
            guard !candidates.isEmpty else { status = "No pedestrian route returned by MapKit."; return }
            routes = candidates; selected = 0; busy = false; loadingBuildings = true
            let loaded = await CityBuildingProvider.shared.load(routes:candidates.map { $0.coordinates.map(\.geo) },buffer:buffer)
            guard requestID == token else { return }
            loadingBuildings = false; dataNote = loaded.note
            if loaded.completeFetch { records = loaded.records }
            else if candidates.allSatisfy({ $0.coordinates.allSatisfy(Self.inCoverage) }) {
                var all:[String:BuildingRecord]=[:]
                for route in candidates {
                    let coords=route.coordinates
                    for record in (try? await LocalBuildingProvider().buildings(around:MKPolyline(coordinates:coords,count:coords.count),bufferMeters:buffer)) ?? [] { all[record.id]=record }
                }
                guard requestID == token else { return }
                records=Array(all.values); dataNote="Offline Marina sample · incomplete building coverage"
            }

            recalculate()
        } catch {
            guard requestID == token else { return }
            let separation = CLLocation(latitude:start.latitude,longitude:start.longitude).distance(from:CLLocation(latitude:finish.latitude,longitude:finish.longitude))
            if separation > 100_000 {
                status = "Your starting point is about \(Int(separation/1000)) km from your destination. Check the starting point and choose a nearby location."
            } else {
                status = "No walking route was found between these places. Try a nearby street or another starting point."
            }
            #if targetEnvironment(simulator)
            if usesCurrentLocation { status += " The simulator uses a simulated GPS location, which may not be in Dubai." }
            #endif
        }
    }
    func recalculate() {
        selectedSample = nil
        guard !routes.isEmpty else { return }
        let unknown = records.count-cachedBuildings.count
        guard !records.isEmpty else {
            exposureTask?.cancel(); calculating=false
            for i in routes.indices { routes[i].exposure = nil }
            status = "Building data unavailable here. Sun minutes withheld."
            return
        }
        let p = projection, b = buildings, date = departure, engine = ShadeEngine(maximumSearchDistance:buffer)
        exposureTask?.cancel(); calculating = true
        let inputs=routes.map { ($0.id,$0.coordinates.map { p.geoToLocal($0.geo) },$0.expectedTravelTime) }
        let token=requestID
        exposureTask=Task {
            do { try await Task.sleep(for:.milliseconds(150)) } catch { return }
            let output = await Task.detached(priority:.userInitiated) {
                inputs.map { id,points,time in
                    (id,RouteExposureService.calculate(points:points,expectedTravelTime:time,buildings:b,engine:engine) { point,seconds in
                        SolarPositionService.position(at:date.addingTimeInterval(seconds),coordinate:p.localToGeo(point))
                    })
                }
            }.value
            guard !Task.isCancelled, requestID == token, departure == date else { return }
            for (id,result) in output { if let i=routes.firstIndex(where: { $0.id == id }) { routes[i].exposure=result } }
            exposureRevision += 1
            calculating=false
            exportDiagnostics()
        }
        status = "Incomplete height model: \(unknown) missing heights/invalid footprints excluded. Sun minutes are model upper estimates. Orange = potential sun; green = known blocker. \(Int(buffer)) m search limit."
        if solar.elevationDegrees > 0 && solar.elevationDegrees < 2 { status += " Low sun: distant blockers may be missed." }
        if routes.count == 1 { status += " Only one walking route available." }
    }
    private func exportDiagnostics() {
        guard !AppConfiguration.googleEnabled,
              ProcessInfo.processInfo.arguments.contains("--city-test") || ProcessInfo.processInfo.arguments.contains("--demo-autoload") else { return }
        let output: [[String:Any]] = routes.map { route in
            ["distance":route.distance,"travelSeconds":route.expectedTravelTime,
             "coordinates":route.coordinates.map { ["latitude":$0.latitude,"longitude":$0.longitude] },
             "sunSecondsUpperEstimate":route.exposure?.sunSeconds as Any? ?? NSNull(),
             "samples":route.exposure?.samples.map { value -> [String:Any] in
                let geo = projection.localToGeo(value.sample.point)
                return ["latitude":geo.latitude,"longitude":geo.longitude,"sun":value.decision.directSun,
                        "building":value.decision.buildingID as Any? ?? NSNull(),
                        "azimuth":value.solar.azimuthDegrees,"elevation":value.solar.elevationDegrees]
             } ?? []]
        }
        if let data = try? JSONSerialization.data(withJSONObject:output,options:.prettyPrinted),
           let folder = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {
            try? data.write(to:folder.appendingPathComponent("last-analysis.json"))
            try? JSONEncoder().encode(records).write(to:folder.appendingPathComponent("last-buildings.json"))
        }
    }

}
