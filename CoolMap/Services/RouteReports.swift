import Foundation
import Combine
struct RouteReport: Codable, Identifiable {
    var id=UUID()
    let category:String
    let note:String
    let coordinate:GeoPoint
    let date:Date
    let locationDescription:String
    var shared:Bool=false
}
@MainActor
final class RouteReportStore: ObservableObject {
    @Published private(set) var reports:[RouteReport]=[]
    @Published private(set) var nearby:[RouteReport]=[]
    @Published var sending=false
    @Published var message:String?
    private let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("route-reports-v2.json")
    init() { if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([RouteReport].self,from:data) { reports=saved } }
    func save(_ report:RouteReport) async throws {
        let updated=[report]+reports
        try persist(updated); reports=updated
        await sync()
    }
    func sync() async {
        guard !sending else { return }
        guard AppConfiguration.sharedReportsEnabled else { message="Sharing is not configured in this build. Your report is saved in the outbox on this device."; return }
        sending=true; defer { sending=false }
        do {
            for report in reports where !report.shared {
                let body:[String:Any]=["id":report.id.uuidString,"category":report.category,"note":report.note,"latitude":report.coordinate.latitude,"longitude":report.coordinate.longitude,"location_description":report.locationDescription]
                let data=try JSONSerialization.data(withJSONObject:body)
                let (_,response)=try await URLSession.shared.data(for:request(query:"",body:data))
                let status=(response as? HTTPURLResponse)?.statusCode ?? 0
                // A repeated UUID is an idempotent retry after an interrupted response.
                guard (200..<300).contains(status) || status==409 else { throw URLError(.badServerResponse) }
                var updated=reports
                if let index=updated.firstIndex(where:{$0.id==report.id}) { updated[index].shared=true }
                try persist(updated); reports=updated
            }
            message="Shared with other walkers. Community reports are unverified."
        } catch { message="Saved to your outbox. Couldn’t share yet; retry when connected." }
    }
    func refresh(around point:GeoPoint) async {
        guard AppConfiguration.sharedReportsEnabled else { return }
        let query="?latitude=gte.\(point.latitude-0.02)&latitude=lte.\(point.latitude+0.02)&longitude=gte.\(point.longitude-0.02)&longitude=lte.\(point.longitude+0.02)&order=created_at.desc&limit=100"
        do {
            let (data,response)=try await URLSession.shared.data(for:request(query:query))
            guard (response as? HTTPURLResponse)?.statusCode==200 else { throw URLError(.badServerResponse) }
            let rows=try JSONDecoder().decode([SharedReport].self,from:data)
            nearby=rows.compactMap(\.report)
        } catch { message="Nearby reports couldn’t be loaded." }
    }
    private func persist(_ values:[RouteReport]) throws { try JSONEncoder().encode(values).write(to:url,options:[.atomic,.completeFileProtection]) }
    private func request(query:String,body:Data?=nil) throws -> URLRequest {
        let host=AppConfiguration.reportsHost
        guard host.range(of:"^[a-z0-9-]+\\.supabase\\.co$",options:.regularExpression) != nil,
              let url=URL(string:"https://\(host)/rest/v1/route_reports\(query)") else { throw URLError(.badURL) }
        var request=URLRequest(url:url); request.timeoutInterval=20
        request.setValue(AppConfiguration.reportsKey,forHTTPHeaderField:"apikey")
        if AppConfiguration.reportsKey.hasPrefix("eyJ") { request.setValue("Bearer "+AppConfiguration.reportsKey,forHTTPHeaderField:"Authorization") }
        if let body { request.httpMethod="POST"; request.httpBody=body; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("return=minimal",forHTTPHeaderField:"Prefer") }
        return request
    }
    private struct SharedReport:Decodable {
        let id:UUID,category:String,note:String,latitude:Double,longitude:Double,created_at:String,location_description:String
        var report:RouteReport? {
            let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let date=formatter.date(from:created_at) ?? ISO8601DateFormatter().date(from:created_at)
            guard let date else { return nil }
            return .init(id:id,category:category,note:note,coordinate:.init(latitude:latitude,longitude:longitude),date:date,locationDescription:location_description,shared:true)
        }
    }
}
