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
    @Published var stepFree = UserDefaults.standard.bool(forKey:"step-free") {
        didSet {
            UserDefaults.standard.set(stepFree,forKey:"step-free")
            if stepFree, let best=bestStepFree, let i=routes.firstIndex(where:{$0.id==best}) { selected=i }
        }
    }
    @Published private(set) var barriers:[AccessBarrier]=[]
    @Published var dataNote = ""
    private var exposureTask: Task<Void,Never>?
    private var requestID = UUID()
    func invalidate() {
        exposureTask?.cancel(); loadingBuildings = false; calculating = false; requestID = UUID(); busy = false; routes = []; records = []; barriers = []; selectedSample = nil; status = ""
    }
    func chooseOrigin(_ coordinate: CLLocationCoordinate2D, name: String, current: Bool = false) {
        invalidate(); origin = coordinate; originName = name; hasOrigin = true; usesCurrentLocation = current
    }
    func chooseDestination(_ coordinate: CLLocationCoordinate2D, name: String) {
        invalidate(); destination = coordinate; destinationName = name; hasDestination = true
    }
    func demo() async {
        // Public Abu Dhabi locations, never presented as the user's GPS position.
        chooseOrigin(.init(latitude:24.49088,longitude:54.35495),name:"Jeddah Street · Abu Dhabi demo")
        chooseDestination(.init(latitude:24.48821,longitude:54.35630),name:"World Trade Center")
        setHour(16); await load()
    }
    var shortest:UUID? { routes.min { $0.distance < $1.distance }?.id }
    var shadeEstimate:UUID? {
        guard !buildings.isEmpty,routes.allSatisfy({ $0.exposure != nil }) else { return nil }
        return routes.min { $0.exposure!.sunSeconds < $1.exposure!.sunSeconds }?.id
    }
    func swapEndpoints() async {
        let oldOrigin=origin, oldName=originName
        chooseOrigin(destination,name:destinationName)
        chooseDestination(oldOrigin,name:oldName)
        await load()
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
    var coolest: UUID? {
        routes.compactMap { route in heatCost(for:route).map { (route.id,$0) } }.min(by: { $0.1 < $1.1 })?.0
    }
    func heatCost(for route: RouteOption) -> Double? {
        route.exposure.map { RouteHeat.cost($0,expectedTravelTime:route.expectedTravelTime) }
    }
    /// Reports that physically block a wheelchair or stroller, as map barriers.
    var reportBarriers:[AccessBarrier] {
        RouteReportStore.shared.active.filter { $0.hazard.isAccessBarrier }.map {
            AccessBarrier(id:"report-\($0.id.uuidString)",kind:$0.hazard.barrierKind,points:[$0.coordinate],detail:$0.hazard.rawValue+($0.note.isEmpty ? "" : " · "+$0.note),blocking:true)
        }
    }
    func accessibility(_ route:RouteOption)->RouteAccessibility {
        StepFreeAssessment.assess(route:route.coordinates.map(\.geo),barriers:barriers+reportBarriers)
    }
    var bestStepFree: UUID? {
        guard !routes.isEmpty else { return nil }
        let ranked = routes.map { ($0,accessibility($0)) }
        return (ranked.filter { $0.1.isStepFree }.isEmpty ? ranked : ranked.filter { $0.1.isStepFree })
            .min { $0.1.adjustedSeconds(expected:$0.0.expectedTravelTime) < $1.1.adjustedSeconds(expected:$1.0.expectedTravelTime) }?.0.id
    }
    func eta(_ route:RouteOption)->Double {
        stepFree ? accessibility(route).adjustedSeconds(expected:route.expectedTravelTime) : route.expectedTravelTime
    }
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
        routes = []; records = []; barriers = []; selectedSample = nil; status = ""
        let start = origin, finish = destination
        do {
            let returned = try await DirectionsService().routes(from:start,to:finish)
            let candidates=returned.filter { WalkLimit.allows(seconds:$0.expectedTravelTime) }
            guard !candidates.isEmpty || returned.isEmpty else { status="Destination is too far. Choose a walk of one hour or less, or change your starting point."; return }
            guard requestID == token else { return }
            guard !candidates.isEmpty else { status = "No walking route available. Choose a nearby destination."; return }
            routes = candidates; selected = 0; busy = false; loadingBuildings = true
            let loaded = await CityBuildingProvider.shared.load(routes:candidates.map { $0.coordinates.map(\.geo) },buffer:buffer)
            guard requestID == token else { return }
            loadingBuildings = false; dataNote = loaded.note
            if loaded.completeFetch { records = loaded.records; barriers = loaded.barriers }
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
            if usesCurrentLocation { status += " The simulator uses a simulated GPS location, which may not be in Abu Dhabi." }
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
             "heatCost":heatCost(for:route) as Any? ?? NSNull(),
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
