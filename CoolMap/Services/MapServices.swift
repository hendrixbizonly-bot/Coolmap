import Foundation
import MapKit
import CoreLocation
import Combine

extension CLLocationCoordinate2D {
    var geo: GeoPoint { .init(latitude:latitude,longitude:longitude) }
}
extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude:latitude,longitude:longitude) }
}
extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: .init(), count:pointCount)
        getCoordinates(&result,range:NSRange(location:0,length:pointCount))
        return result
    }
}
struct WalkingStep {
    let instructions:String
    let distance:Double
}
struct RouteOption: Identifiable {
    let id = UUID()
    let coordinates:[CLLocationCoordinate2D]
    let expectedTravelTime:Double
    let distance:Double
    let steps:[WalkingStep]
    let provider:String
    var exposure:RouteExposure?
    init(routes:[MKRoute]) {
        coordinates=routes.flatMap { $0.polyline.coordinates }
        expectedTravelTime=routes.reduce(0) { $0+$1.expectedTravelTime }
        distance=routes.reduce(0) { $0+$1.distance }
        steps=routes.flatMap(\.steps).filter { !$0.instructions.isEmpty }.map { .init(instructions:$0.instructions,distance:$0.distance) }
        provider="Apple"
    }
    init(coordinates:[CLLocationCoordinate2D],expectedTravelTime:Double,distance:Double,steps:[WalkingStep],provider:String) {
        self.coordinates=coordinates; self.expectedTravelTime=expectedTravelTime; self.distance=distance; self.steps=steps; self.provider=provider
    }
}
@MainActor
struct DirectionsService {
    func routes(from: CLLocationCoordinate2D,to: CLLocationCoordinate2D) async throws -> [RouteOption] {
        if AppConfiguration.googleEnabled { return try await GoogleRouteService.routes(from:from,to:to) }
        let direct = try await leg(from:from,to:to,alternates:true)
        var options = direct.map { RouteOption(routes:[$0]) }
        if options.count == 1 && AppModel.inCoverage(from) && AppModel.inCoverage(to) {
            // A real MapKit pedestrian detour through the demo district; no fabricated lines.
            let waypoint = CLLocationCoordinate2D(latitude:25.0781,longitude:55.1410)
            if let first = try? await leg(from:from,to:waypoint,alternates:false).first,
               let second = try? await leg(from:waypoint,to:to,alternates:false).first {
                let candidate = RouteOption(routes:[first,second])
                if abs(candidate.distance-options[0].distance) > 20 { options.append(candidate) }
            }
        }
        return options
    }
    private func leg(from:CLLocationCoordinate2D,to:CLLocationCoordinate2D,alternates:Bool) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:from))
        request.destination = MKMapItem(placemark:MKPlacemark(coordinate:to))
        request.transportType = .walking; request.requestsAlternateRoutes = alternates
        return try await MKDirections(request:request).calculate().routes
    }
}
protocol BuildingDataProvider {
    func buildings(around route:MKPolyline,bufferMeters:Double) async throws -> [BuildingRecord]
}
struct LocalBuildingProvider: BuildingDataProvider {
    func buildings(around route:MKPolyline,bufferMeters:Double) async throws -> [BuildingRecord] {
        guard let url = Bundle.main.url(forResource:"buildings",withExtension:"json") else { throw CocoaError(.fileNoSuchFile) }
        let all = try JSONDecoder().decode([BuildingRecord].self,from:Data(contentsOf:url))
        let projection = CoordinateProjection(origin:route.coordinates.first!.geo)
        let points = route.coordinates.map { projection.geoToLocal($0.geo) }
        let minX = points.map(\.x).min()!-bufferMeters, maxX = points.map(\.x).max()!+bufferMeters
        let minY = points.map(\.y).min()!-bufferMeters, maxY = points.map(\.y).max()!+bufferMeters
        return all.filter { building in
            let footprint = building.footprint.map(projection.geoToLocal)
            guard let left = footprint.map(\.x).min(), let right = footprint.map(\.x).max(),
                  let bottom = footprint.map(\.y).min(), let top = footprint.map(\.y).max() else { return false }
            return right >= minX && left <= maxX && top >= minY && bottom <= maxY
        }
    }
}
@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var heading = 0.0
    @Published var lastFix: CLLocation?
    private var tracking = false
    func startTracking() { tracking=true; request() }
    func stopTracking() { tracking=false; manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }
    @Published var error: String?
    @Published var locating = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest }
    func request() {
        error = nil; locating = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if tracking { manager.startUpdatingLocation(); manager.startUpdatingHeading() } else { manager.requestLocation() }
        default: locating = false; error = "Location is off. Allow location in Settings, or choose a starting point."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if locating { request() }
    }
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        locating = false
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        lastFix=fix; coordinate = fix.coordinate
    }
    func locationManager(_ manager: CLLocationManager,didUpdateHeading newHeading:CLHeading) { heading=newHeading.trueHeading>=0 ? newHeading.trueHeading : newHeading.magneticHeading }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) {
        locating = false; self.error = "Couldn’t get your location. Try again or choose a starting point."
    }
}

@MainActor
final class SearchService: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { updateQuery() } }
    @Published var error:String?
    @Published var results:[PlaceSuggestion]=[]
    private let completer=MKLocalSearchCompleter()
    private var searchTask:Task<Void,Never>?
    private let session=UUID().uuidString
    override init() {
        super.init(); completer.delegate=self; completer.resultTypes=[.address,.pointOfInterest]
        completer.region=MKCoordinateRegion(center:.init(latitude:25.20,longitude:55.27),latitudinalMeters:50000,longitudinalMeters:50000)
    }
    private func updateQuery() {
        error=nil; searchTask?.cancel()
        if query.isEmpty { results=[]; return }
        if AppConfiguration.googleEnabled {
            let text=query
            searchTask=Task {
                do {
                    try await Task.sleep(for:.milliseconds(250))
                    let matches=try await GooglePlaceService.autocomplete(text,session:session)
                    guard !Task.isCancelled,query==text else { return }
                    results=matches
                } catch { if !Task.isCancelled { self.error="Search is unavailable. Check your Google API setup and connection." } }
            }
        } else { completer.queryFragment=query }
    }
    func completer(_ completer:MKLocalSearchCompleter,didFailWithError error:Error) { self.error="Search is unavailable. Check your connection and try again." }
    func completerDidUpdateResults(_ completer:MKLocalSearchCompleter) {
        guard !query.isEmpty else { return }
        results=completer.results.enumerated().map { index,value in .init(id:"apple-\(index)-\(value.title)",title:value.title,subtitle:value.subtitle,apple:value) }
    }
    func resolve(_ result:PlaceSuggestion) async throws -> MKMapItem? {
        if AppConfiguration.googleEnabled { return try await GooglePlaceService.resolve(result,session:session) }
        guard let apple=result.apple else { return nil }
        return try await MKLocalSearch(request:MKLocalSearch.Request(completion:apple)).start().mapItems.first
    }
}
