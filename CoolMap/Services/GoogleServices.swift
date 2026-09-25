import Foundation
import MapKit

enum GoogleHTTP {
    static func request(url:URL,body:[String:Any]? = nil,fields:String? = nil) async throws -> Data {
        var request=URLRequest(url:url); request.timeoutInterval=25
        request.setValue(AppConfiguration.servicesKey,forHTTPHeaderField:"X-Goog-Api-Key")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.hendrix.coolmap",forHTTPHeaderField:"X-Ios-Bundle-Identifier")
        if let fields { request.setValue(fields,forHTTPHeaderField:"X-Goog-FieldMask") }
        if let body { request.httpMethod="POST"; request.httpBody=try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
enum GoogleRouteService {
    struct Response:Decodable { let routes:[Route]? }
    struct Route:Decodable {
        let distanceMeters:Double
        let duration:String
        let polyline:Polyline
        let legs:[Leg]
    }
    struct Polyline:Decodable { let encodedPolyline:String }
    struct Leg:Decodable { let steps:[Step] }
    struct Step:Decodable {
        let distanceMeters:Double?
        let navigationInstruction:Instruction?
    }
    struct Instruction:Decodable { let instructions:String? }
    static func routes(from:CLLocationCoordinate2D,to:CLLocationCoordinate2D) async throws -> [RouteOption] {
        func waypoint(_ p:CLLocationCoordinate2D) -> [String:Any] { ["location":["latLng":["latitude":p.latitude,"longitude":p.longitude]]] }
        let body:[String:Any]=["origin":waypoint(from),"destination":waypoint(to),"travelMode":"WALK","computeAlternativeRoutes":true,"polylineQuality":"HIGH_QUALITY","languageCode":"en","units":"METRIC"]
        let data=try await GoogleHTTP.request(url:URL(string:"https://routes.googleapis.com/directions/v2:computeRoutes")!,body:body,fields:"routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.distanceMeters,routes.legs.steps.navigationInstruction")
        return try JSONDecoder().decode(Response.self,from:data).routes?.compactMap { route in
            let coordinates=EncodedPolyline.decode(route.polyline.encodedPolyline).map(\.coordinate)
            guard coordinates.count>1,let seconds=Double(route.duration.dropLast()),seconds>0 else { return nil }
            return RouteOption(coordinates:coordinates,expectedTravelTime:seconds,distance:route.distanceMeters,steps:route.legs.flatMap(\.steps).compactMap { step in
                guard let text=step.navigationInstruction?.instructions else { return nil }
                return WalkingStep(instructions:text,distance:step.distanceMeters ?? 0)
            },provider:"Google")
        } ?? []
    }
}
struct PlaceSuggestion: Identifiable, Hashable {
    let id:String
    let title:String
    let subtitle:String
    var apple:MKLocalSearchCompletion?
    static func ==(a:Self,b:Self)->Bool { a.id==b.id }
    func hash(into hasher:inout Hasher) { hasher.combine(id) }
}
enum GooglePlaceService {
    static func autocomplete(_ text:String,session:String) async throws -> [PlaceSuggestion] {
        let data=try await GoogleHTTP.request(url:URL(string:"https://places.googleapis.com/v1/places:autocomplete")!,body:["input":text,"sessionToken":session,"includedRegionCodes":["ae"],"locationBias":["circle":["center":["latitude":25.20,"longitude":55.27],"radius":50000]]])
        let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        return (json?["suggestions"] as? [[String:Any]] ?? []).compactMap { suggestion in
            guard let prediction=suggestion["placePrediction"] as? [String:Any],let id=prediction["placeId"] as? String else { return nil }
            let format=prediction["structuredFormat"] as? [String:Any]
            let title=(format?["mainText"] as? [String:Any])?["text"] as? String ?? "Place"
            let subtitle=(format?["secondaryText"] as? [String:Any])?["text"] as? String ?? ""
            return .init(id:id,title:title,subtitle:subtitle)
        }
    }
    static func resolve(_ suggestion:PlaceSuggestion,session:String) async throws -> MKMapItem? {
        var url=URLComponents(string:"https://places.googleapis.com/v1/places/\(suggestion.id)")!
        url.queryItems=[.init(name:"sessionToken",value:session)]
        let data=try await GoogleHTTP.request(url:url.url!,fields:"location,displayName")
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let location=json["location"] as? [String:Double],let lat=location["latitude"],let lon=location["longitude"] else { return nil }
        let item=MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:lat,longitude:lon))); item.name=suggestion.title
        return item
    }
}
