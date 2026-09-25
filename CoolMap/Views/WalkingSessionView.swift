import SwiftUI
import MapKit
import AVFoundation
struct WalkingSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State var route:RouteOption
    @ObservedObject var location:LocationService
    @ObservedObject private var reports=RouteReportStore.shared
    let destinationName:String
    var routeColor:Color = .blue
    var stepFree=false
    var barriers:[AccessBarrier]=[]
    var alternative:RouteOption? = nil
    @State private var position=MapCameraPosition.automatic
    @State private var progress:WalkingProgress?
    @State private var steps=false
    @State private var report=false
    @State private var follow=true
    @State private var previewing=true
    @State private var demo=false
    @State private var demoDistance=0.0
    @State private var cameraHeading=0.0
    private let demoTimer=Timer.publish(every:1,on:.main,in:.common).autoconnect()
    private let freshnessTimer=Timer.publish(every:5,on:.main,in:.common).autoconnect()
    @State private var speech=AVSpeechSynthesizer()
    /// Stage demo: a simulated walker moves along the route into a pin another walker reported 10 min ago.
    @State private var stageDemo=false
    @State private var demoHazardDistance=0.0
    private let stageTimer=Timer.publish(every:0.5,on:.main,in:.common).autoconnect()
    @State private var walkStarted:Date?
    @State private var lastReroutePrompt:Date?
    @State private var rerouteInFlight=false
    @State private var rerouteBanner:(heatReduction:Int,extraMinutes:Int,ahead:String?)?
    @State private var sentReports:Set<UUID>=[]
    @State private var walkingActive=false
    private let rerouteTimer=Timer.publish(every:10,on:.main,in:.common).autoconnect()
    private static let demoMetresPerSecond=3.0
    private let panel=Color(red:0.055,green:0.09,blue:0.14)
    private var origin:CLLocationCoordinate2D { route.coordinates.first ?? .init(latitude:25.2,longitude:55.27) }
    private var projection:CoordinateProjection { .init(origin:origin.geo) }
    private var onRoute:Bool { progress.map { $0.distanceOffRoute<45 } ?? false }
    private var routePoints:[LocalPoint] { route.coordinates.map { projection.geoToLocal($0.geo) } }
    private var demoPose:(coordinate:CLLocationCoordinate2D,heading:Double) {
        let points=routePoints
        guard points.count>1 else { return (origin,0) }
        var remaining=demoDistance
        for index in 1..<points.count {
            let a=points[index-1],b=points[index],delta=b-a,length=delta.length
            guard length>0 else { continue }
            if remaining<=length || index==points.count-1 {
                let point=a+delta*min(1,remaining/length)
                return (projection.localToGeo(point).coordinate,(atan2(delta.x,delta.y)*180 / .pi+360).truncatingRemainder(dividingBy:360))
            }
            remaining-=length
        }
        return (origin,0)
    }
    private var walkingHeading:Double {
        if stageDemo { return demoHeading }
        if demo { return demoPose.heading }
        if let fix=location.lastFix,fix.course>=0,fix.speed>0.5 { return fix.course }
        return location.heading
    }
    private var maneuverSymbol:String {
        let text=instruction.lowercased()
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("destination") { return "flag.checkered" }
        return "arrow.up"
    }
    private var stepDistance:Double {
        var accumulated=0.0
        for step in route.steps {
            accumulated+=step.distance
            if accumulated>(progress?.distanceFromStart ?? 0)+5 { return max(0,accumulated-(progress?.distanceFromStart ?? 0)) }
        }
        return progress?.remainingDistance ?? route.distance
    }
    private var freshCoordinate:CLLocationCoordinate2D? {
        if stageDemo { return coordinate(alongRoute:demoDistance) }
        if demo { return demoPose.coordinate }
        guard let fix=location.lastFix,abs(fix.timestamp.timeIntervalSinceNow)<30,
              fix.horizontalAccuracy>=0,fix.horizontalAccuracy<65 else { return nil }
        return fix.coordinate
    }
    private var followCoordinate:CLLocationCoordinate2D? {
        guard progress?.canFollowLocation == true else { return nil }
        return freshCoordinate
    }
    private var previewMessage:String {
        "Waiting for a nearby GPS location. You can preview the walk with Demo walk."
    }
    private var nextStep:WalkingStep? {
        guard !route.steps.isEmpty else { return nil }
        let distance=progress?.distanceFromStart ?? 0
        var accumulated=0.0
        for step in route.steps { accumulated+=step.distance; if accumulated>distance+5 { return step } }
        return route.steps.last
    }
    private var instruction:String {
        if followCoordinate == nil { return "Route preview" }
        if !onRoute { return "Head to the walking route" }
        if (progress?.remainingDistance ?? 100)>20 { return nextStep?.instructions ?? "Continue along the route" }
        return "You’re near your destination"
    }
    private var demoHeading:Double {
        guard stageDemo,let a=coordinate(alongRoute:demoDistance),let b=coordinate(alongRoute:demoDistance+15) else { return location.heading }
        let dLon=(b.longitude-a.longitude)*Double.pi/180,lat1=a.latitude*Double.pi/180,lat2=b.latitude*Double.pi/180
        let y=sin(dLon)*cos(lat2),x=cos(lat1)*sin(lat2)-sin(lat1)*cos(lat2)*cos(dLon)
        return (atan2(y,x)*180/Double.pi+360).truncatingRemainder(dividingBy:360)
    }
    /// Point `metres` along the route polyline (nil if the route is empty).
    private func coordinate(alongRoute metres:Double)->CLLocationCoordinate2D? {
        let c=route.coordinates
        guard let first=c.first else { return nil }
        var left=max(0,metres)
        for (a,b) in zip(c,c.dropFirst()) {
            let seg=RouteReportStore.distance(a.geo,b.geo)
            if left<=seg,seg>0 { let t=left/seg; return .init(latitude:a.latitude+(b.latitude-a.latitude)*t,longitude:a.longitude+(b.longitude-a.longitude)*t) }
            left-=seg
        }
        return c.count>1 ? c.last : first
    }
    private var access:RouteAccessibility { StepFreeAssessment.assess(route:route.coordinates.map(\.geo),barriers:barriers) }
    /// Wheelchair/stroller pace and slope/surface penalties replace MapKit's estimate when step-free is on.
    private var expectedSeconds:Double { stepFree ? access.adjustedSeconds(expected:route.expectedTravelTime) : route.expectedTravelTime }
    private func setStageDemo(_ on:Bool,category:HazardCategory = .other,note:String = "Fallen tree across the path") {
        stageDemo=on
        if on { demo=false }
        guard on else { reports.clearDemoHazards(); update(); return }
        // Pin the hazard ~150 m in, or mid-route on short walks, and start the walker 90 m before it.
        demoHazardDistance=min(150,route.distance*0.6)
        demoDistance=max(0,demoHazardDistance-90)
        if let p=coordinate(alongRoute:demoHazardDistance) { reports.plantStageDemo(at:p.geo,category:category,note:note,ageMinutes:10) }
        follow=true; previewing=false; update()
    }
    var body:some View {
        activeMap
        .safeAreaInset(edge:.top) {
            HStack(spacing:16) {
                Image(systemName:maneuverSymbol).font(.system(size:36,weight:.bold)).frame(width:46)
                VStack(alignment:.leading,spacing:7) {
                    if followCoordinate != nil { Text("In \(Int(stepDistance.rounded())) m").font(.subheadline).opacity(0.85) }
                    Text(instruction).font(.title3.bold())
                    Text((followCoordinate == nil ? destinationName : onRoute ? ((demo || stageDemo) ? "DEMO WALK · simulated location" : "Walking to \(destinationName)") : "Head to the nearby route")+(stepFree ? " · step-free pace" : "")).font(.caption).opacity(0.8)
                }
                Spacer()
            }.padding(20).coolGlass().padding(12)
        }
        .overlay(alignment:.top) {
            if let r=reports.verification { StillThereCard(store:reports,report:r).padding(.horizontal,16).transition(.move(edge:.top).combined(with:.opacity)) }
        }
        .overlay(alignment:.trailing) {
            VStack(spacing:14) {
                Button { follow=true; previewing=false; update() } label: { Image(systemName:"location.viewfinder").font(.title2).padding().background(panel,in:Circle()) }.accessibilityLabel("Show route or nearby location")
                HazardReportButton { report=true }
            }.padding()
        }
        .overlay(alignment:.bottomLeading) {
            VStack(alignment:.leading,spacing:8) {
                if stageDemo,let tree=reports.demo.first {
                    let gap=Int(max(0,demoHazardDistance-demoDistance))
                    Text(gap>0 ? "Another walker reported “\(tree.summary)” 10 min ago · \(gap) m ahead" : "You’re at the reported hazard")
                        .font(.caption).padding(.horizontal,12).padding(.vertical,8).background(panel,in:Capsule())
                }
                Menu {
                    Button("Fallen tree ahead") { setStageDemo(true) }
                    Button("Broken elevator (step-free)") { setStageDemo(true,category:.brokenElevator,note:"Lift out of service — use the ramp on the north side") }
                    if stageDemo { Button("Stop demo",role:.destructive) { setStageDemo(false) } }
                } label: {
                    Label(stageDemo ? "Stop demo" : "Stage demo",systemImage:"figure.walk.motion").font(.caption.bold()).foregroundStyle(.orange).padding(.horizontal,12).padding(.vertical,8).background(panel,in:Capsule())
                }
                .accessibilityHint("Simulates walking this route into a hazard another walker reported")
            }.padding().padding(.bottom,10)
        }
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:8) {
                if let banner=rerouteBanner {
                    VStack(spacing:8) {
                        Text(banner.ahead.map { "Cooler way available · \($0) ahead · +\(banner.extraMinutes) min" } ?? "Cooler way available · \(banner.heatReduction)% less heat · +\(banner.extraMinutes) min").font(.subheadline.bold())
                        HStack {
                            Button("Switch") { switchRoute() }
                            Spacer()
                            Button("Dismiss") { rerouteBanner=nil }
                        }
                    }.padding(16).coolGlass()
                }
            VStack(spacing:18) {
                if let p=progress,onRoute {
                    HStack {
                        metric("\(Int(ceil(p.remainingSeconds/60))) min","remaining")
                        Spacer(); metric(String(format:"%.1f km",p.remainingDistance/1000),"distance")
                        Spacer(); metric(Date().addingTimeInterval(p.remainingSeconds).formatted(date:.omitted,time:.shortened),"arrival estimate")
                    }
                } else {
                    Text("\(Int(ceil(expectedSeconds/60))) min · \(Int(route.distance)) m walk").font(.headline)
                    Text(followCoordinate == nil ? previewMessage : "Join the route to start tracking your walk.").font(.caption).foregroundStyle(.secondary)
                    if followCoordinate == nil {
                        Button("Demo walk") { if stageDemo { setStageDemo(false) }; demo=true; demoDistance=0; follow=true; update() }.buttonStyle(.borderedProminent)
                    }
                }
                if demo { Button("Stop demo") { demo=false; progress=nil; showRoute(); update() }.font(.caption) }
                HStack(alignment:.top) {
                    action("Hear",icon:"speaker.wave.2.fill") { speech.speak(AVSpeechUtterance(string:instruction)) }
                    Spacer(); action("Steps",icon:"list.bullet") { steps=true }
                    Spacer(); action("Report",icon:"exclamationmark.bubble") { report=true }
                    Spacer(); action("End",icon:"xmark",color:.red) { dismiss() }
                }
            }.padding(20).coolGlass()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { walkingActive=true; showRoute(); location.startTracking(); update() }
        .onDisappear { walkingActive=false; location.stopTracking(); speech.stopSpeaking(at:.immediate); if stageDemo { reports.clearDemoHazards() } }
        .onReceive(rerouteTimer) { _ in Task { await checkReroute() } }
        .task(id:followCoordinate != nil) {
            guard followCoordinate != nil,!AppConfiguration.rerouteURL.isEmpty,walkStarted == nil else { return }
            walkStarted=Date()
            do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
            await checkReroute()
        }
        .onReceive(demoTimer) { _ in
            guard demo else { return }
            // Accelerated preview, independent of the user's real GPS.
            let length=zip(routePoints,routePoints.dropFirst()).reduce(0.0) { $0+($1.1-$1.0).length }
            demoDistance=min(length,demoDistance+8)
            withAnimation(.linear(duration:1)) { update() }
        }
        .onReceive(freshnessTimer) { _ in update() }
        .onChange(of:reports.active.map(\.id)) { _,_ in update() }
        .onReceive(stageTimer) { _ in
            guard stageDemo,demoDistance<route.distance,reports.verification==nil else { return }
            demoDistance+=Self.demoMetresPerSecond*0.5
            update()
            if let c=freshCoordinate { reports.checkProximity(to:c.geo) }
        }
        .onReceive(location.$coordinate) { c in guard !stageDemo else { return }; update(); if let c { reports.checkProximity(to:c.geo) } }
        .onReceive(location.$heading) { _ in if follow && !stageDemo { update() } }
        .sheet(isPresented:$steps) { WalkNavigationView(route:route,location:location) }
        .sheet(isPresented:$report) { HazardReportSheet(store:reports,coordinate:(followCoordinate ?? origin).geo,locationDescription:demo || stageDemo ? "Simulated demo position (not GPS)" : followCoordinate == nil ? "Route start (preview — not your GPS location)" : "Your current GPS position") }
    }
    @ViewBuilder private var activeMap:some View {
        #if canImport(GoogleMaps)
        if AppConfiguration.googleEnabled {
            GoogleRouteMap(routes:[route],selected:route.id,origin:origin,destination:route.coordinates.last,followCoordinate:followCoordinate,heading:walkingHeading,routeTint:UIColor(routeColor),navigationArrow:true)
        } else { appleMap }
        #else
        appleMap
        #endif
    }
    private var appleMap:some View {
        Map(position:$position) {
            Annotation((demo || stageDemo) ? "Demo position" : followCoordinate == nil ? "Route start" : "You",coordinate:followCoordinate ?? origin) {
                Image(systemName:"location.north.fill")
                    .font(.system(size:30,weight:.bold)).foregroundStyle(.blue)
                    .rotationEffect(.degrees((followCoordinate == nil ? demoPose.heading : walkingHeading)-cameraHeading))
                    .frame(width:56,height:56).background(.white,in:Circle())
                    .overlay(Circle().stroke(.blue.opacity(0.2),lineWidth:6))
                    .shadow(color:.black.opacity(0.25),radius:7,y:3)
            }.annotationTitles(.hidden)
            MapPolyline(coordinates:route.coordinates).stroke(.white,lineWidth:10)
            MapPolyline(coordinates:route.coordinates).stroke(routeColor,lineWidth:6)
            if let end=route.coordinates.last { Marker(destinationName,coordinate:end).tint(.red) }
            ForEach(reports.active) { r in Marker(r.hazard.rawValue,systemImage:r.hazard.icon,coordinate:r.coordinate.coordinate).tint(r.hazard.color) }
            if stepFree {
                ForEach(barriers.filter { !$0.id.hasPrefix("report-") }) { b in
                    if b.points.count>=2 { MapPolyline(coordinates:b.points.map(\.coordinate)).stroke(.red,lineWidth:5) }
                    else if let point=b.points.first { Marker(b.detail,systemImage:b.kind.mapIcon,coordinate:point.coordinate).tint(.red) }
                }
            }
        }.mapStyle(.standard(elevation:.realistic,pointsOfInterest:.excludingAll))
        .onMapCameraChange { context in
            cameraHeading=context.camera.heading
            if position.positionedByUser { follow=false }
        }
    }
    @MainActor private func checkReroute() async {
        guard walkingActive,!AppConfiguration.rerouteURL.isEmpty,!rerouteInFlight,
              let coordinate=followCoordinate,let progress,let exposure=route.exposure else { return }
        let now=Date(),routeID=route.id
        if walkStarted == nil { walkStarted=now }
        let currentHeat=RouteHeat.cost(exposure,expectedTravelTime:route.expectedTravelTime,fromDistance:progress.distanceFromStart)
        let alt=alternative.flatMap { $0.id != routeID ? $0 : nil }
        let altHeat=alt.flatMap { option in option.exposure.map { RouteHeat.cost($0,expectedTravelTime:option.expectedTravelTime) } }
        let alternativeBody:Any
        if let alt,let exposure=alt.exposure,let altHeat {
            alternativeBody=["totalSeconds":alt.expectedTravelTime,"heat":altHeat,"sunSeconds":exposure.sunSeconds]
        } else { alternativeBody=NSNull() }
        let pinned=reports.active.compactMap { report -> (RouteReport,Double)? in
            guard let pin=WalkingProgress.calculate(point:projection.geoToLocal(report.coordinate),route:routePoints,expectedSeconds:route.expectedTravelTime),pin.distanceOffRoute<=30,pin.distanceFromStart>=progress.distanceFromStart else { return nil }
            return (report,pin.distanceFromStart-progress.distanceFromStart)
        }
        let hazards:[[String:Any]]=pinned.map { report,ahead in
            ["category":report.hazard.rawValue,"note":report.note,"metersAhead":ahead,"minutesAgo":Int(-report.date.timeIntervalSinceNow/60),"confirmed":report.confirmedAt != nil]
        }
        sentReports.formUnion(pinned.map { $0.0.id })
        let formatter=ISO8601DateFormatter()
        formatter.timeZone=TimeZone(secondsFromGMT:4*3600)
        let body:[String:Any]=[
            "lat":coordinate.latitude,"lon":coordinate.longitude,"localTime":formatter.string(from:now),
            "offRouteMeters":progress.distanceOffRoute,"offRouteSeconds":0,
            "walkedSeconds":max(0,now.timeIntervalSince(walkStarted ?? now)),
            "secondsSinceLastPrompt":lastReroutePrompt.map { max(0,now.timeIntervalSince($0)) } ?? 9999,
            "minutesToSunset":120,
            "current":["remainingSeconds":progress.remainingSeconds,"remainingHeat":currentHeat,"remainingSunSeconds":exposure.sunSeconds],
            "alternative":alternativeBody,"hazardsAhead":hazards]
        rerouteInFlight=true
        defer { rerouteInFlight=false }
        guard let decision=await RerouteService.decide(body),decision.prompt,walkingActive,route.id==routeID,
              followCoordinate != nil,rerouteBanner == nil,
              lastReroutePrompt.map({ Date().timeIntervalSince($0)>=60 }) ?? true,
              let alt,let altHeat else { return }
        rerouteBanner=(currentHeat>0 ? max(0,Int(((1-altHeat/currentHeat)*100).rounded())) : 0,max(0,Int(ceil((alt.expectedTravelTime-progress.remainingSeconds)/60))),pinned.first?.0.summary)
        lastReroutePrompt=Date()
    }
    private func switchRoute() {
        guard let alternative,alternative.id != route.id else { return }
        route=alternative
        rerouteBanner=nil
        demoDistance=0
        if stageDemo { reports.clearDemoHazards(); demoHazardDistance=0 }
        follow=true
        update()
    }
    private func metric(_ value:String,_ caption:String) -> some View { VStack(alignment:.leading) { Text(value).font(.title3.bold()); Text(caption).font(.caption).foregroundStyle(.secondary) } }
    private func action(_ title:String,icon:String,color:Color = .blue,action:@escaping ()->Void) -> some View { Button(action:action) { VStack(spacing:8) { Image(systemName:icon).font(.title3); Text(title).font(.caption) }.foregroundStyle(color) } }
    private func showRoute() {
        previewing=true
        guard !route.coordinates.isEmpty else { return }
        let rect=MKPolyline(coordinates:route.coordinates,count:route.coordinates.count).boundingMapRect
        position = .rect(rect.insetBy(dx:-max(300,rect.width*0.25),dy:-max(300,rect.height*0.25)))
    }
    private func update() {
        guard let coordinate=freshCoordinate else { progress=nil; if !previewing { showRoute() }; return }
        progress=WalkingProgress.calculate(point:projection.geoToLocal(coordinate.geo),route:route.coordinates.map { projection.geoToLocal($0.geo) },expectedSeconds:expectedSeconds)
        guard progress?.canFollowLocation == true else { if !previewing { showRoute() }; return }
        previewing=false
        if follow { position = .camera(.init(centerCoordinate:coordinate,distance:350,heading:walkingHeading,pitch:50)) }
        if walkingActive,!AppConfiguration.rerouteURL.isEmpty,let progress,unsentHazardAhead(progress) { Task { await checkReroute() } }
    }
    private func unsentHazardAhead(_ progress:WalkingProgress) -> Bool {
        reports.active.contains { report in
            guard !sentReports.contains(report.id),let pin=WalkingProgress.calculate(point:projection.geoToLocal(report.coordinate),route:routePoints,expectedSeconds:route.expectedTravelTime) else { return false }
            let ahead=pin.distanceFromStart-progress.distanceFromStart
            return pin.distanceOffRoute<=30 && ahead>=0 && ahead<=200
        }
    }
}
