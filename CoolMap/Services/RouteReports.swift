import Foundation
import Combine
import SwiftUI

/// Pedestrian hazards walkers can report with one tap. Each kind clears itself after a lifetime that
/// matches how long the problem usually lasts, so the map never fills with stale pins.
enum HazardCategory: String, CaseIterable, Codable, Identifiable {
    case brokenSidewalk="Broken sidewalk"
    case blockedCrossing="Blocked crossing"
    case noShade="No shade"
    case construction="Construction"
    case other="Other"
    var id:String { rawValue }
    var icon:String {
        switch self {
        case .brokenSidewalk: return "road.lanes.curved.right"
        case .blockedCrossing: return "figure.walk.diamond.fill"
        case .noShade: return "sun.max.trianglebadge.exclamationmark.fill"
        case .construction: return "cone.fill"
        case .other: return "exclamationmark.triangle.fill"
        }
    }
    var color:Color {
        switch self {
        case .brokenSidewalk: return Color(red:0.95,green:0.45,blue:0.2)
        case .blockedCrossing: return Color(red:0.9,green:0.25,blue:0.3)
        case .noShade: return Color(red:0.98,green:0.72,blue:0.15)
        case .construction: return Color(red:1,green:0.55,blue:0.1)
        case .other: return Color(red:0.6,green:0.5,blue:0.9)
        }
    }
    var lifetime:TimeInterval {
        switch self {
        case .blockedCrossing: return 6*3600
        case .other: return 24*3600
        case .brokenSidewalk, .construction: return 14*86400
        case .noShade: return 30*86400
        }
    }
    var lifetimeLabel:String {
        let hours=Int(lifetime/3600)
        return hours<48 ? "Clears after \(hours) h" : "Clears after \(hours/24) days"
    }
    /// Names stored by earlier builds and the shared table.
    init(legacy name:String) {
        switch name {
        case "Blocked path","No pavement": self = .brokenSidewalk
        case "Missing shade": self = .noShade
        default: self = HazardCategory(rawValue:name) ?? .other
        }
    }
}

struct RouteReport: Codable, Identifiable {
    var id=UUID()
    let category:String
    let note:String
    let coordinate:GeoPoint
    let date:Date
    let locationDescription:String
    var shared:Bool=false
    /// Set when a walker confirmed the hazard; the decay timer restarts from that moment.
    var confirmedAt:Date?
    /// Weighted “Not there” votes; the pin clears once these reach `RouteReport.clearThreshold`.
    var denials:Double=0
    static let clearThreshold=2.0
    var hazard:HazardCategory { HazardCategory(legacy:category) }
    /// What the walker is being asked about: the reporter's note when there is one, else the category.
    var summary:String { note.isEmpty ? hazard.rawValue : note }
    var expiresAt:Date { (confirmedAt ?? date).addingTimeInterval(hazard.lifetime) }
    var isActive:Bool { expiresAt>Date() && denials<RouteReport.clearThreshold }
    init(id:UUID=UUID(),category:String,note:String,coordinate:GeoPoint,date:Date,locationDescription:String,shared:Bool=false,confirmedAt:Date?=nil,denials:Double=0) {
        self.id=id; self.category=category; self.note=note; self.coordinate=coordinate; self.date=date
        self.locationDescription=locationDescription; self.shared=shared; self.confirmedAt=confirmedAt; self.denials=denials
    }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id); category=try c.decode(String.self,forKey:.category); note=try c.decode(String.self,forKey:.note)
        coordinate=try c.decode(GeoPoint.self,forKey:.coordinate); date=try c.decode(Date.self,forKey:.date)
        locationDescription=try c.decode(String.self,forKey:.locationDescription); shared=try c.decodeIfPresent(Bool.self,forKey:.shared) ?? false
        confirmedAt=try c.decodeIfPresent(Date.self,forKey:.confirmedAt); denials=try c.decodeIfPresent(Double.self,forKey:.denials) ?? 0
    }
}

/// Waze-style “Still there?” weighting without accounts: a per-device score that grows as you answer prompts.
/// Server-side accuracy scoring can lower it once votes are aggregated.
struct WalkerReputation:Codable {
    var answered=0
    var score=1.0
    /// How much one vote from this device counts, 0.5–2.0.
    var weight:Double { min(2,max(0.5,score)) }
    mutating func recordAnswer() { answered+=1; if answered%5==0 { score=min(2,score+0.25) } }
}

@MainActor
final class RouteReportStore: ObservableObject {
    static let shared=RouteReportStore()
    @Published private(set) var reports:[RouteReport]=[]
    @Published private(set) var nearby:[RouteReport]=[]
    @Published var sending=false
    @Published var message:String?
    private let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("route-reports-v2.json")
    private let reputationKey="walker-reputation"
    @Published private(set) var reputation=WalkerReputation()
    /// Report ids already prompted on this device with the time, so one pin doesn’t nag repeatedly.
    private var prompted:[UUID:Date]=[:]
    /// Hazard the walker is close enough to check with their own eyes.
    @Published var verification:RouteReport?
    static let promptRadiusMeters=40.0
    static let promptCooldown:TimeInterval=30*60
    init() {
        if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([RouteReport].self,from:data) { reports=saved }
        if let data=UserDefaults.standard.data(forKey:reputationKey),let saved=try? JSONDecoder().decode(WalkerReputation.self,from:data) { reputation=saved }
        purgeExpired()
    }
    /// Called with each location fix. Picks the closest active pin inside the trigger zone that hasn’t
    /// been asked about recently. Your own fresh reports are skipped (you just placed them).
    func checkProximity(to point:GeoPoint) {
        guard verification==nil else { return }
        let now=Date()
        let mine=Set(reports.map(\.id))
        let candidate=active.filter { r in
            (prompted[r.id].map { now.timeIntervalSince($0)>RouteReportStore.promptCooldown } ?? true)
            && (!mine.contains(r.id) || now.timeIntervalSince(r.date)>10*60)
        }.map { ($0,Self.distance($0.coordinate,point)) }.filter { $0.1<=RouteReportStore.promptRadiusMeters }.min { $0.1<$1.1 }
        guard let (report,_)=candidate else { return }
        prompted[report.id]=now
        verification=report
    }
    /// “Still there”: restarts the decay timer. “Not there”: adds a weighted negative vote; the pin clears at the threshold.
    func answerVerification(stillThere:Bool) {
        guard let report=verification else { return }
        verification=nil
        var rep=reputation; rep.recordAnswer(); reputation=rep; saveReputation()
        update(report.id) { r in
            if stillThere { r.confirmedAt=Date() } else { r.denials+=rep.weight }
        }
        Task { await sendVote(report:report,stillThere:stillThere) }
    }
    func dismissVerification() { verification=nil }
    private func update(_ id:UUID,_ change:(inout RouteReport)->Void) {
        var updated=reports
        if let i=updated.firstIndex(where:{$0.id==id}) { change(&updated[i]); try? persist(updated); reports=updated }
        var near=nearby
        if let i=near.firstIndex(where:{$0.id==id}) { change(&near[i]); nearby=near }
        var d=demo
        if let i=d.firstIndex(where:{$0.id==id}) { change(&d[i]); demo=d.filter(\.isActive) }
        purgeExpired()
    }
    private func saveReputation() { if let data=try? JSONEncoder().encode(reputation) { UserDefaults.standard.set(data,forKey:reputationKey) } }
    private func sendVote(report:RouteReport,stillThere:Bool) async {
        guard AppConfiguration.sharedReportsEnabled, !demo.contains(where:{$0.id==report.id}) else { return }
        let body:[String:Any]=["report_id":report.id.uuidString,"still_there":stillThere,"weight":reputation.weight]
        guard let data=try? JSONSerialization.data(withJSONObject:body),var request=try? request(query:"",body:data) else { return }
        request.url=request.url.flatMap { URL(string:$0.absoluteString.replacingOccurrences(of:"route_reports",with:"route_report_votes")) }
        _=try? await URLSession.shared.data(for:request)
    }
    static func distance(_ a:GeoPoint,_ b:GeoPoint)->Double {
        let r=6371000.0,dLat=(b.latitude-a.latitude)*Double.pi/180,dLon=(b.longitude-a.longitude)*Double.pi/180
        let h=sin(dLat/2)*sin(dLat/2)+cos(a.latitude*Double.pi/180)*cos(b.latitude*Double.pi/180)*sin(dLon/2)*sin(dLon/2)
        return 2*r*asin(min(1,sqrt(h)))
    }
    /// Unexpired pins for the map: your own reports plus nearby community reports, deduplicated by id.
    var active:[RouteReport] {
        var seen=Set<UUID>()
        return (reports+nearby+demo).filter { $0.isActive && seen.insert($0.id).inserted }
    }
    /// Demo mode: sample “community” hazards planted around a point so the Still there? flow can be shown
    /// without walking a route or waiting for another user. Never persisted or uploaded.
    @Published private(set) var demo:[RouteReport]=[]
    var demoMode:Bool { !demo.isEmpty }
    /// Stage demo: one pin on the walker's own route, as if another walker reported it 10 minutes ago.
    /// Returns the pin so the caller can position the simulated walk relative to it.
    @discardableResult func plantStageDemo(at p:GeoPoint)->RouteReport {
        let r=RouteReport(category:HazardCategory.other.rawValue,note:"Fallen tree across the path",coordinate:p,date:Date()-10*60,locationDescription:"Reported by another walker")
        demo=[r]
        return r
    }
    func clearDemoHazards() { demo=[]; if let v=verification, !reports.contains(where:{$0.id==v.id}) && !nearby.contains(where:{$0.id==v.id}) { verification=nil } }
    func purgeExpired() {
        let now=Date()
        let kept=reports.filter { $0.expiresAt>now && $0.denials<RouteReport.clearThreshold }
        if kept.count != reports.count { try? persist(kept); reports=kept }
        nearby=nearby.filter { $0.expiresAt>now && $0.denials<RouteReport.clearThreshold }
    }
    func save(_ report:RouteReport) async throws {
        let updated=[report]+reports
        try persist(updated); reports=updated
        await sync()
    }
    func sync() async {
        guard !sending else { return }
        guard AppConfiguration.sharedReportsEnabled else { message="Sharing is not configured in this build. Your report is saved on this device."; return }
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
            nearby=rows.compactMap(\.report).filter(\.isActive)
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
