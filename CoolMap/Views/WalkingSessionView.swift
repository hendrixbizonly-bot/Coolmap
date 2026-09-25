import SwiftUI
import MapKit
import AVFoundation
struct WalkingSessionView: View {
    @Environment(\.dismiss) private var dismiss
    let route:RouteOption
    @ObservedObject var location:LocationService
    @ObservedObject private var reports=RouteReportStore.shared
    let destinationName:String
    @State private var position=MapCameraPosition.automatic
    @State private var progress:WalkingProgress?
    @State private var steps=false
    @State private var report=false
    @State private var follow=true
    @State private var previewing=true
    private let freshnessTimer=Timer.publish(every:5,on:.main,in:.common).autoconnect()
    @State private var speech=AVSpeechSynthesizer()
    private let panel=Color(red:0.055,green:0.09,blue:0.14)
    private var origin:CLLocationCoordinate2D { route.coordinates.first ?? .init(latitude:25.2,longitude:55.27) }
    private var projection:CoordinateProjection { .init(origin:origin.geo) }
    private var onRoute:Bool { progress.map { $0.distanceOffRoute<45 } ?? false }
    private var freshCoordinate:CLLocationCoordinate2D? {
        guard let fix=location.lastFix,abs(fix.timestamp.timeIntervalSinceNow)<30,
              fix.horizontalAccuracy>=0,fix.horizontalAccuracy<65 else { return nil }
        return fix.coordinate
    }
    private var followCoordinate:CLLocationCoordinate2D? {
        guard progress?.canFollowLocation == true else { return nil }
        return freshCoordinate
    }
    private var previewMessage:String {
        #if targetEnvironment(simulator)
        return "The simulator’s GPS is away from this walk or unavailable. Showing your Dubai route. Live guidance starts when GPS is near the route."
        #else
        return "Your location is away from this walk or unavailable. Showing your route. Live guidance starts when you’re nearby."
        #endif
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
    var body:some View {
        activeMap
        .safeAreaInset(edge:.top) {
            HStack(spacing:16) {
                Image(systemName:"location.north.fill").font(.largeTitle)
                VStack(alignment:.leading,spacing:7) {
                    Text(instruction).font(.headline)
                    Text(followCoordinate == nil ? destinationName : onRoute ? "Following your location · walking estimate" : "Head to the nearby route").font(.caption).opacity(0.8)
                }
                Spacer()
            }.padding(20).background(.blue,in:RoundedRectangle(cornerRadius:20)).padding(12)
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
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:18) {
                if let p=progress,onRoute {
                    HStack {
                        metric("\(Int(ceil(p.remainingSeconds/60))) min","remaining")
                        Spacer(); metric(String(format:"%.1f km",p.remainingDistance/1000),"distance")
                        Spacer(); metric(Date().addingTimeInterval(p.remainingSeconds).formatted(date:.omitted,time:.shortened),"arrival estimate")
                    }
                } else {
                    Text("\(Int(ceil(route.expectedTravelTime/60))) min · \(Int(route.distance)) m walk").font(.headline)
                    Text(followCoordinate == nil ? previewMessage : "Join the route to start tracking your walk.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment:.top) {
                    action("Hear",icon:"speaker.wave.2.fill") { speech.speak(AVSpeechUtterance(string:instruction)) }
                    Spacer(); action("Steps",icon:"list.bullet") { steps=true }
                    Spacer(); action("Report",icon:"exclamationmark.bubble") { report=true }
                    Spacer(); action("End",icon:"xmark",color:.red) { dismiss() }
                }
            }.padding(20).background(panel)
        }
        .preferredColorScheme(.dark)
        .onAppear { showRoute(); location.startTracking(); update() }
        .onDisappear { location.stopTracking(); speech.stopSpeaking(at:.immediate) }
        .onReceive(freshnessTimer) { _ in update() }
        .onReceive(location.$coordinate) { c in update(); if let c { reports.checkProximity(to:c.geo) } }
        .onReceive(location.$heading) { _ in if follow { update() } }
        .sheet(isPresented:$steps) { WalkNavigationView(route:route,location:location) }
        .sheet(isPresented:$report) { HazardReportSheet(store:reports,coordinate:(followCoordinate ?? origin).geo,locationDescription:followCoordinate == nil ? "Route start (preview — not your GPS location)" : "Your current GPS position") }
    }
    @ViewBuilder private var activeMap:some View {
        #if canImport(GoogleMaps)
        if AppConfiguration.googleEnabled {
            GoogleRouteMap(routes:[route],selected:route.id,origin:origin,destination:route.coordinates.last,followCoordinate:followCoordinate,heading:location.heading)
        } else { appleMap }
        #else
        appleMap
        #endif
    }
    private var appleMap:some View {
        Map(position:$position) {
            if followCoordinate != nil { UserAnnotation() }
            Marker("Start",coordinate:origin).tint(.blue)
            MapPolyline(coordinates:route.coordinates).stroke(.white,lineWidth:10)
            MapPolyline(coordinates:route.coordinates).stroke(.blue,lineWidth:6)
            if let end=route.coordinates.last { Marker(destinationName,coordinate:end).tint(.red) }
            ForEach(reports.active) { r in Marker(r.hazard.rawValue,systemImage:r.hazard.icon,coordinate:r.coordinate.coordinate).tint(r.hazard.color) }
        }.mapStyle(.standard(elevation:.realistic,pointsOfInterest:.excludingAll))
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
        progress=WalkingProgress.calculate(point:projection.geoToLocal(coordinate.geo),route:route.coordinates.map { projection.geoToLocal($0.geo) },expectedSeconds:route.expectedTravelTime)
        guard progress?.canFollowLocation == true else { if !previewing { showRoute() }; return }
        previewing=false
        if follow { position = .camera(.init(centerCoordinate:coordinate,distance:500,heading:location.heading,pitch:55)) }
    }
}
