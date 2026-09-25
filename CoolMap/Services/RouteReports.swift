import Foundation
import Combine
import SwiftUI
import CoreLocation

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
    var reporterID:UUID?
    var serverExpiresAt:Date?
    /// Set when a walker confirmed the hazard; the decay timer restarts from that moment.
    var confirmedAt:Date?
    /// Weighted “Not there” votes; the pin clears once these reach `RouteReport.clearThreshold`.
    var denials:Double=0
    static let clearThreshold=2.0
    var hazard:HazardCategory { HazardCategory(legacy:category) }
    /// What the walker is being asked about: the reporter's note when there is one, else the category.
    var summary:String { note.isEmpty ? hazard.rawValue : note }
    var expiresAt:Date { serverExpiresAt ?? (confirmedAt ?? date).addingTimeInterval(hazard.lifetime) }
    var isActive:Bool { expiresAt>Date() && denials<RouteReport.clearThreshold }
    init(id:UUID=UUID(),category:String,note:String,coordinate:GeoPoint,date:Date,locationDescription:String,shared:Bool=false,confirmedAt:Date?=nil,denials:Double=0,reporterID:UUID?=nil,serverExpiresAt:Date?=nil) {
        self.id=id; self.category=category; self.note=note; self.coordinate=coordinate; self.date=date
        self.locationDescription=locationDescription; self.shared=shared; self.confirmedAt=confirmedAt; self.denials=denials
        self.reporterID=reporterID; self.serverExpiresAt=serverExpiresAt
    }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id); category=try c.decode(String.self,forKey:.category); note=try c.decode(String.self,forKey:.note)
        coordinate=try c.decode(GeoPoint.self,forKey:.coordinate); date=try c.decode(Date.self,forKey:.date)
        locationDescription=try c.decode(String.self,forKey:.locationDescription); shared=try c.decodeIfPresent(Bool.self,forKey:.shared) ?? false
        confirmedAt=try c.decodeIfPresent(Date.self,forKey:.confirmedAt); denials=try c.decodeIfPresent(Double.self,forKey:.denials) ?? 0
        reporterID=try c.decodeIfPresent(UUID.self,forKey:.reporterID); serverExpiresAt=try c.decodeIfPresent(Date.self,forKey:.serverExpiresAt)
    }
}

@MainActor
final class RouteReportStore: ObservableObject {
    static let shared=RouteReportStore()
    @Published private(set) var reports:[RouteReport]=[]
    @Published private(set) var nearby:[RouteReport]=[]
    @Published var sending=false
    @Published var message:String?
    private let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("route-reports-v2.json")
    @Published private(set) var voting=false
    @Published private(set) var verificationError:String?
    private var latestFix:CLLocation?
    private var answered=Set<UUID>()
    /// Report ids already prompted on this device with the time, so one pin doesn’t nag repeatedly.
    private var prompted:[UUID:Date]=[:]
    /// Hazard the walker is close enough to check with their own eyes.
    @Published var verification:RouteReport?
    static let promptRadiusMeters=40.0
    static let promptCooldown:TimeInterval=30*60
    init() {
        if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([RouteReport].self,from:data) { reports=saved }
        purgeExpired()
    }
    /// Called with each location fix. Picks the closest active pin inside the trigger zone that hasn’t
    /// been asked about recently. Your own fresh reports are skipped (you just placed them).
    func checkProximity(to point:GeoPoint,fix:CLLocation?=nil,simulated:Bool=false) {
        if !simulated { latestFix=fix }
        guard verification==nil else { return }
        let now=Date()
        let mine=Set(reports.map(\.id))
        let candidate=active.filter { r in
            (prompted[r.id].map { now.timeIntervalSince($0)>RouteReportStore.promptCooldown } ?? true)
            && !answered.contains(r.id) && !mine.contains(r.id)
            && (demo.contains(where:{$0.id==r.id}) || (!simulated && r.reporterID != nil && WalkerAccount.shared.isSignedIn && r.reporterID != WalkerAccount.shared.userID))
        }.map { ($0,Self.distance($0.coordinate,point)) }.filter { $0.1<=RouteReportStore.promptRadiusMeters }.min { $0.1<$1.1 }
        guard let (report,_)=candidate else { return }
        prompted[report.id]=now
        verificationError=nil
        verification=report
    }
    /// “Still there”: restarts the decay timer. “Not there”: adds a weighted negative vote; the pin clears at the threshold.
    func answerVerification(stillThere:Bool) {
        guard let report=verification,!voting else { return }
        verificationError=nil
        if demo.contains(where:{$0.id==report.id}) {
            update(report.id) { if stillThere { $0.confirmedAt=Date() } else { $0.denials+=1 } }
            verification=nil; message="Demo check saved. No real points changed."; return
        }
        guard let fix=latestFix,abs(fix.timestamp.timeIntervalSinceNow)<120,fix.horizontalAccuracy>=0,fix.horizontalAccuracy<=65 else {
            verificationError="A fresh GPS location is needed. Move closer and try again."; return
        }
        voting=true
        Task {
            defer { voting=false }
            do {
                let account=WalkerAccount.shared,owner=account.userID
                let token=try await account.accessToken()
                _=try await CommunityAPI.request("rest/v1/rpc/verify_owned_report",method:"POST",body:["p_report_id":report.id.uuidString,"p_still_there":stillThere,"p_latitude":fix.coordinate.latitude,"p_longitude":fix.coordinate.longitude,"p_accuracy":fix.horizontalAccuracy,"p_observed_at":ISO8601DateFormatter().string(from:fix.timestamp)],token:token)
                guard account.userID==owner else { return }
                answered.insert(report.id); verification=nil
                message="Thanks — your check was saved. The reporter’s points have been updated."
                await refresh(around:report.coordinate)
                await account.refreshProfile()
            } catch { verificationError=error.localizedDescription }
        }
    }
    func dismissVerification() { if !voting { verification=nil; verificationError=nil } }
    func accountChanged() { verification=nil; verificationError=nil; answered=[]; prompted=[:] }
    private func update(_ id:UUID,_ change:(inout RouteReport)->Void) {
        var updated=reports
        if let i=updated.firstIndex(where:{$0.id==id}) { change(&updated[i]); try? persist(updated); reports=updated }
        var near=nearby
        if let i=near.firstIndex(where:{$0.id==id}) { change(&near[i]); nearby=near }
        var d=demo
        if let i=d.firstIndex(where:{$0.id==id}) { change(&d[i]); demo=d.filter(\.isActive) }
        purgeExpired()
    }
    static func distance(_ a:GeoPoint,_ b:GeoPoint)->Double {
        let r=6371000.0,dLat=(b.latitude-a.latitude)*Double.pi/180,dLon=(b.longitude-a.longitude)*Double.pi/180
        let h=sin(dLat/2)*sin(dLat/2)+cos(a.latitude*Double.pi/180)*cos(b.latitude*Double.pi/180)*sin(dLon/2)*sin(dLon/2)
        return 2*r*asin(min(1,sqrt(h)))
    }
    /// Unexpired pins for the map: your own reports plus nearby community reports, deduplicated by id.
    var active:[RouteReport] {
        var seen=Set<UUID>()
        let mine=reports.filter { $0.reporterID==nil || $0.reporterID==WalkerAccount.shared.userID }
        return (nearby+mine+demo).filter { $0.isActive && seen.insert($0.id).inserted }
    }
    /// Demo mode: sample “community” hazards planted around a point so the Still there? flow can be shown
    /// without walking a route or waiting for another user. Never persisted or uploaded.
    @Published private(set) var demo:[RouteReport]=[]
    var demoMode:Bool { !demo.isEmpty }
    /// Local fixtures only: never enter the upload outbox or real points ledger.
    func seedDemoRoute(_ points:[GeoPoint]) {
        guard points.count>1 else { return }
        let segments=zip(points,points.dropFirst()).map { Self.distance($0,$1) }
        let total=segments.reduce(0,+)
        func point(_ fraction:Double)->GeoPoint {
            var remaining=total*fraction
            for i in segments.indices {
                if remaining<=segments[i],segments[i]>0 {
                    let t=remaining/segments[i],a=points[i],b=points[i+1]
                    return GeoPoint(latitude:a.latitude+(b.latitude-a.latitude)*t,longitude:a.longitude+(b.longitude-a.longitude)*t)
                }
                remaining-=segments[i]
            }
            return points.last!
        }
        let fixtures:[(HazardCategory,String,Double,Bool)]=[
            (.noShade,"Shade sail torn down",0.25,true),
            (.construction,"Scaffolding beside walkway; passage open",0.55,true),
            (.brokenSidewalk,"Uneven paving near entrance",0.8,false)
        ]
        demo=fixtures.map { category,note,fraction,confirmed in
            RouteReport(category:category.rawValue,note:note,coordinate:point(fraction),date:Date()-600,locationDescription:"Demo · community report",confirmedAt:confirmed ? Date()-120 : nil)
        }
        verification=nil
    }
    /// Stage demo: one pin on the walker's own route, as if another walker reported it 10 minutes ago.
    /// Returns the pin so the caller can position the simulated walk relative to it.
    @discardableResult func plantStageDemo(at p:GeoPoint)->RouteReport {
        let r=RouteReport(category:HazardCategory.noShade.rawValue,note:"Shade sail torn down",coordinate:p,date:Date()-10*60,locationDescription:"Demo · reported by another walker")
        demo=[r]+Array(demo.dropFirst())
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
        var owned=report; owned.reporterID=WalkerAccount.shared.userID
        let updated=[owned]+reports
        try persist(updated); reports=updated
        await sync()
    }
    func sync() async {
        guard !sending else { return }
        guard AppConfiguration.sharedReportsEnabled else { message="Sharing is not configured in this build. Your report is saved on this device."; return }
        guard let owner=WalkerAccount.shared.userID else { message="Saved on this device. Sign in before creating reports to earn community points."; return }
        sending=true; defer { sending=false }
        do {
            for report in reports where !report.shared && report.reporterID==owner {
                guard WalkerAccount.shared.userID==owner else { return }
                let token=try await WalkerAccount.shared.accessToken()
                let body:[String:Any]=["p_id":report.id.uuidString,"p_category":report.category,"p_note":report.note,"p_latitude":report.coordinate.latitude,"p_longitude":report.coordinate.longitude,"p_description":String(report.locationDescription.prefix(120))]
                _=try await CommunityAPI.request("rest/v1/rpc/submit_owned_report",method:"POST",body:body,token:token)
                var updated=reports
                if let index=updated.firstIndex(where:{$0.id==report.id}) { updated[index].shared=true }
                try persist(updated); reports=updated
            }
            message="Shared with other walkers. Community reports are unverified."
        } catch { message="Saved to your outbox. \(error.localizedDescription)" }
    }
    func refresh(around point:GeoPoint) async {
        guard AppConfiguration.sharedReportsEnabled else { return }
        let query="?latitude=gte.\(point.latitude-0.02)&latitude=lte.\(point.latitude+0.02)&longitude=gte.\(point.longitude-0.02)&longitude=lte.\(point.longitude+0.02)&order=created_at.desc&limit=100"
        do {
            let data=try await CommunityAPI.request("rest/v1/route_reports\(query)")
            let rows=try JSONDecoder().decode([SharedReport].self,from:data)
            let fetched=rows.compactMap(\.report)
            var local=reports
            for row in fetched { if let index=local.firstIndex(where:{$0.id==row.id && $0.shared}) { local[index]=row } }
            try persist(local); reports=local; nearby=fetched.filter(\.isActive)
            if let owner=WalkerAccount.shared.userID {
                let token=try await WalkerAccount.shared.accessToken()
                let votes=try await CommunityAPI.request("rest/v1/route_report_votes?voter_id=eq.\(owner.uuidString)&select=report_id",token:token)
                struct Vote:Decodable { let report_id:UUID }
                if WalkerAccount.shared.userID==owner { answered=Set(try JSONDecoder().decode([Vote].self,from:votes).map(\.report_id)) }
            }
        } catch { message="Nearby reports couldn’t be loaded." }
    }
    private func persist(_ values:[RouteReport]) throws { try JSONEncoder().encode(values).write(to:url,options:[.atomic,.completeFileProtection]) }
    private struct SharedReport:Decodable {
        let id:UUID,category:String,note:String,latitude:Double,longitude:Double,created_at:String,location_description:String
        let reporter_id:UUID?
        let confirmed_at:String?
        let expires_at:String?
        let denials:Double?
        var report:RouteReport? {
            let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let date=formatter.date(from:created_at) ?? ISO8601DateFormatter().date(from:created_at)
            guard let date else { return nil }
            return .init(id:id,category:category,note:note,coordinate:.init(latitude:latitude,longitude:longitude),date:date,locationDescription:location_description,shared:true,confirmedAt:confirmed_at.flatMap(CommunityAPI.date),denials:denials ?? 0,reporterID:reporter_id,serverExpiresAt:expires_at.flatMap(CommunityAPI.date))
        }
    }
}
