import SwiftUI
import MapKit

struct MapScreen: View {
    @StateObject private var model = AppModel()
    @StateObject private var location = LocationService()
    @ObservedObject private var reports = RouteReportStore.shared
    @State private var reporting = false
    @State private var mapCenter = MapCenter()
    @State private var searchOrigin: Bool?
    @State private var settings = false
    @State private var timePicker = false
    @State private var navigation = false
    @State private var heightLabels = false
    @State private var minute=960.0
    @State private var playing=false
    @State private var scrubbing=false
    @State private var heading=0.0
    @State private var polygons:[[GeoPoint]]=[]
    @State private var shadowRevision=0
    @State private var shadowTask:Task<Void,Never>?
    @State private var updatingShadows=false
    private let ticker=Timer.publish(every:0.8,on:.main,in:.common).autoconnect()
    private let expiryTicker=Timer.publish(every:60,on:.main,in:.common).autoconnect()

    @State private var position = MapCameraPosition.region(MKCoordinateRegion(center:.init(latitude:25.20,longitude:55.27),latitudinalMeters:18000,longitudinalMeters:18000))
    private let panel = Color(red:0.055,green:0.09,blue:0.14)
    private let accent = Color(red:0.25,green:0.50,blue:1)
    var body: some View {
        ZStack {
            if navigation { panel } else { activeMap.ignoresSafeArea(edges:.horizontal) }
            if !model.routes.isEmpty && !navigation { sunBadge }
            if let report=reports.verification, !navigation {
                VStack { StillThereCard(store:reports,report:report).padding(.horizontal,16).padding(.top,8); Spacer() }
                    .transition(.move(edge:.top).combined(with:.opacity)).animation(.spring,value:report.id)
            }
            VStack {
                Spacer()
                HStack(alignment:.bottom) {
                    Spacer()
                    VStack(spacing:14) {
                        Button { useLocation() } label: {
                            Image(systemName:location.locating ? "location.circle" : "location.fill").font(.title3).frame(width:48,height:48).background(panel,in:Circle())
                        }.accessibilityLabel("Use my location")
                        if !navigation { HazardReportButton { reporting = true } }
                    }
                }
                .overlay(alignment:.bottomLeading) {
                    if reports.demoMode && !navigation, let next=reports.nextDemoHazard {
                        Button { reports.simulateApproach(to:next) } label: {
                            Label("Demo: walk into \(next.summary.lowercased())",systemImage:"figure.walk.motion").font(.caption.bold()).padding(.horizontal,12).padding(.vertical,8).background(panel,in:Capsule())
                        }.accessibilityLabel("Simulate walking into the next demo hazard").padding(.bottom,22)
                    }
                }.padding(.horizontal,20).padding(.bottom,12)
            }
        }
        .background(panel.ignoresSafeArea())
        .safeAreaInset(edge:.top,spacing:0) { topCard.padding(.horizontal,16).padding(.vertical,8).background(panel) }
        .safeAreaInset(edge:.bottom,spacing:0) { bottomCard }
        .preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented:Binding(get:{ searchOrigin != nil },set:{ if !$0 { searchOrigin = nil } })) {
            DestinationSearchView(isOrigin:searchOrigin == true, useLocation:{ searchOrigin = nil; useLocation() }) { item in
                if searchOrigin == true { model.chooseOrigin(item.placemark.coordinate,name:item.name ?? "Starting point") }
                else { model.chooseDestination(item.placemark.coordinate,name:item.name ?? "Destination") }
                searchOrigin = nil
                if !model.hasOrigin { useLocation() }
                else { Task { await model.load() } }
            }
        }
        .sheet(isPresented:$settings) { debugSettings }
        .sheet(isPresented:$reporting) {
            HazardReportSheet(store:reports,coordinate:reportPoint.coordinate,locationDescription:reportPoint.description)
        }
        .onReceive(expiryTicker) { _ in reports.purgeExpired() }
        .onReceive(location.$coordinate) { coordinate in if let coordinate, !navigation { reports.checkProximity(to:coordinate.geo) } }
        .onChange(of:model.hasOrigin) { _,has in if has { Task { await reports.refresh(around:model.origin.geo) } } }
        .sheet(isPresented:$timePicker) {
            NavigationStack {
                Form {
                    DatePicker("Leave at",selection:$model.departure).environment(\.timeZone,TimeZone(identifier:"Asia/Dubai")!)
                    Text("Times shown in Dubai time").font(.caption).foregroundStyle(.secondary)
                    Button("Leave now") { model.departure = Date(); model.recalculate(); timePicker = false }
                }.navigationTitle("Departure time").toolbar { Button("Done") { model.recalculate(); timePicker = false } }
            }.presentationDetents([.height(300)])
        }
        .fullScreenCover(isPresented:$navigation) {
            if let route=model.active { WalkingSessionView(route:route,location:location,destinationName:model.destinationName) }
        }
        .onChange(of:minute) { _,_ in if !scrubbing { commitTime() } }
        .onChange(of:model.recordsRevision) { _,_ in updateShadows() }
        .onChange(of:model.routes.isEmpty) { _,empty in if empty { playing=false }; syncTime(); updateShadows() }
        .onChange(of:navigation) { _,opened in if opened { playing=false } }
        .onReceive(ticker) { _ in
            if playing && !model.calculating && !updatingShadows && !model.loadingBuildings {
                minute=minute>=1435 ? 0 : min(1435,minute+15)
            }
        }
        .onDisappear { playing=false; shadowTask?.cancel() }
        .onReceive(location.$coordinate) { coordinate in
            guard let coordinate, model.usesCurrentLocation, !navigation else { return }
            model.chooseOrigin(coordinate,name:"My location",current:true)
            position = .region(.init(center:coordinate,latitudinalMeters:1800,longitudinalMeters:1800))
            if model.hasDestination { Task { await model.load() } }
        }
        .onChange(of:model.departure) { _,_ in syncTime(); model.recalculate(); updateShadows() }
        .onChange(of:model.busy) { _,busy in if !busy, let route = model.active { fit(route) } }
        .onChange(of:model.selected) { _,_ in if let route = model.active { fit(route) } }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--city-test") {
                model.chooseOrigin(.init(latitude:25.2074,longitude:55.2637),name:"City Walk")
                model.chooseDestination(.init(latitude:25.2014,longitude:55.2691),name:"Burj Khalifa / Dubai Mall Metro")
                model.setHour(15); await model.load()
                if ProcessInfo.processInfo.arguments.contains("--walk-test") { navigation=true }
            } else if ProcessInfo.processInfo.arguments.contains("--demo-autoload") { await model.demo() }
        }
    }
    private var topCard: some View {
        HStack(spacing:14) {
            VStack(spacing:0) {
                Button { searchOrigin = true } label: {
                    HStack(spacing:14) {
                        Image(systemName:"location.circle.fill").foregroundStyle(accent)
                        Text(model.hasOrigin ? model.originName : "My location").foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        if location.locating { ProgressView() }
                    }.frame(height:45).contentShape(Rectangle())
                }.accessibilityLabel("Choose starting point")
                Divider().padding(.leading,34)
                Button { searchOrigin = false } label: {
                    HStack(spacing:14) {
                        Image(systemName:"mappin.circle.fill").foregroundStyle(.mint)
                        Text(model.hasDestination ? model.destinationName : "Where to?").foregroundStyle(model.hasDestination ? .white : .white.opacity(0.6)).lineLimit(1)
                        Spacer()
                        Image(systemName:"magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(height:45).contentShape(Rectangle())
                }.accessibilityLabel("Search destination")
            }
            Button { settings = true } label: { Image(systemName:"slider.horizontal.3").frame(width:32,height:60) }.accessibilityLabel("Map settings")
        }.padding(.horizontal,16).padding(.vertical,6).background(panel,in:RoundedRectangle(cornerRadius:24)).overlay(RoundedRectangle(cornerRadius:24).stroke(.white.opacity(0.1)))
    }
    private var bottomCard: some View {
        VStack(alignment:.leading,spacing:10) {
            Capsule().fill(.white.opacity(0.2)).frame(width:34,height:4).frame(maxWidth:.infinity)
            if let error = location.error, !model.hasOrigin {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("Choose starting point") { searchOrigin = true }
            }
            if model.busy {
                HStack(spacing:12) { ProgressView(); Text("Finding your walk…").font(.headline) }.padding(.vertical,20)
            } else if !model.routes.isEmpty {
                if model.loadingBuildings { ProgressView("Loading nearby buildings…").font(.caption) }
                HStack {
                    Text("Your walk").font(.title2.bold())
                    Spacer()
                    Button { timePicker = true } label: { Label(departureLabel,systemImage:"clock").font(.subheadline) }
                    Button { model.invalidate(); model.hasDestination = false } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear destination")
                }
                ForEach(Array(model.routes.enumerated()),id:\.element.id) { index,route in
                    Button { model.selected = index; model.selectedSample = nil } label: {
                        HStack(spacing:12) {
                            Image(systemName:"figure.walk").font(.title3).frame(width:40,height:40).background(accent.opacity(0.2),in:Circle())
                            VStack(alignment:.leading,spacing:5) {
                                Text(route.id == model.fastest ? "Fastest" : route.id == model.bestShade ? "Most shade" : "Alternative").font(.headline).foregroundStyle(.white)
                                Text(sunText(route)).font(.subheadline).foregroundStyle(route.exposure == nil ? Color.secondary : .orange)
                            }
                            Spacer()
                            VStack(alignment:.trailing,spacing:6) {
                                Text("\(Int(ceil(route.expectedTravelTime/60))) min").font(.headline).foregroundStyle(.white)
                                Text(route.distance < 1000 ? "\(Int(route.distance)) m" : String(format:"%.1f km",route.distance/1000)).font(.caption).foregroundStyle(.secondary)
                            }
                            if model.selected == index { Image(systemName:"checkmark.circle.fill") }
                        }.padding(12).background(model.selected == index ? accent.opacity(0.18) : .white.opacity(0.04),in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(model.selected == index ? accent : .clear,lineWidth:1.5))
                    }.buttonStyle(.plain)
                }
                sunControls
                if model.active?.exposure != nil {
                    HStack(spacing:14) { Label("Shade",systemImage:"circle.fill").foregroundStyle(.green); Label("Possible sun",systemImage:"circle.fill").foregroundStyle(.orange) }.font(.caption)
                    Text("Sun estimates are limited by available building data.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.loadingBuildings ? "Walking directions are ready. Checking building data…" : model.dataNote).font(.caption).foregroundStyle(.secondary)
                    if !model.loadingBuildings { Button("Retry shade data") { Task { await model.load() } }.font(.caption) }
                }
                Button { playing=false; navigation = true } label: { Label("Start walk",systemImage:"location.north.fill").font(.headline).frame(maxWidth:.infinity).padding(16) }.buttonStyle(.plain).foregroundStyle(.white).background(accent,in:Capsule())
            } else {
                Text(model.hasDestination ? "Let’s find your way" : "A little less sun.\nA better walk.").font(.system(size:28,weight:.semibold,design:.rounded))
                Text(model.status.isEmpty || !model.hasDestination ? "Choose where you’re going. We’ll take it from there." : model.status).font(.subheadline).foregroundStyle(.secondary)
                Button { if model.hasDestination && model.hasOrigin { Task { await model.load() } } else { searchOrigin = false } } label: {
                    Label(model.hasDestination && model.hasOrigin ? "Try again" : "Search destination",systemImage:"magnifyingglass").font(.headline).frame(maxWidth:.infinity).padding(16)
                }.buttonStyle(.plain).foregroundStyle(.white).background(accent,in:Capsule())
                if model.hasDestination && !model.status.isEmpty {
                    Button("Change starting point") { searchOrigin = true }.font(.subheadline).frame(maxWidth:.infinity)
                }
                Button("Try a walk in Dubai Marina") { Task { await model.demo() } }.font(.subheadline).frame(maxWidth:.infinity)
            }
        }.padding(20).padding(.bottom,4).background(panel,in:UnevenRoundedRectangle(topLeadingRadius:28,topTrailingRadius:28)).background(alignment:.bottom) { panel.ignoresSafeArea(edges:.bottom).padding(.top,28) }
    }
    private var sunControls:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Label("Sun simulator",systemImage:"sun.max.fill").font(.subheadline.bold())
                Spacer()
                Text("Dubai time").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing:8) {
                Button { playing.toggle() } label: {
                    Image(systemName:playing ? "pause.fill" : "play.fill").frame(width:36,height:36)
                }.accessibilityLabel(playing ? "Pause sun simulation" : "Play sun simulation")
                Slider(value:$minute,in:0...1435,step:5,onEditingChanged:{ editing in
                    scrubbing=editing
                    if editing { playing=false } else { commitTime() }
                }).accessibilityLabel("Time of day").accessibilityValue(timeLabel)
                Text(timeLabel).font(.subheadline.monospacedDigit()).frame(width:48)
            }
            Text(scrubbing ? "Release to update shadows and sun time." : "Move the time slider or press play to see shade change.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
    }
    private var sunBadge:some View {
        GeometryReader { geometry in
            let sun=model.solar
            let angle=(sun.azimuthDegrees-heading)*Double.pi/180
            let radius=max(20,min(geometry.size.width,geometry.size.height)*0.32)
            VStack(spacing:3) {
                Image(systemName:sun.elevationDegrees>0 ? "sun.max.fill" : "moon.fill")
                    .font(.title2).foregroundStyle(sun.elevationDegrees>0 ? .orange : .gray)
                    .padding(10).background(panel.opacity(0.9),in:Circle())
                Text(sun.elevationDegrees>0 ? "Sun" : "After sunset").font(.caption2.bold()).padding(4).background(panel,in:Capsule())
            }.position(x:geometry.size.width/2+sin(angle)*radius,y:geometry.size.height/2-cos(angle)*radius)
                .accessibilityLabel("Sun direction, elevation \(Int(sun.elevationDegrees)) degrees")
        }.allowsHitTesting(false)
    }
    private var timeLabel:String { String(format:"%02d:%02d",Int(minute)/60,Int(minute)%60) }
    private func syncTime() {
        guard !scrubbing else { return }
        var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Dubai")!
        minute=Double(c.component(.hour,from:model.departure)*60+c.component(.minute,from:model.departure))
    }
    private func commitTime() {
        guard !model.routes.isEmpty else { return }
        var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Dubai")!
        let date=c.date(bySettingHour:Int(minute)/60,minute:Int(minute)%60,second:0,of:model.departure)!
        if date != model.departure { model.departure=date }
    }
    private func updateShadows() {
        shadowTask?.cancel()
        let p=model.projection,engine=ShadeEngine(maximumSearchDistance:model.buffer),buildings=model.buildings,solar=model.solar
        updatingShadows=true
        shadowTask=Task {
            do { try await Task.sleep(for:.milliseconds(120)) } catch { return }
            let output=await Task.detached(priority:.userInitiated) {
                buildings.flatMap { engine.shadowQuads(building:$0,solar:solar) }.map { $0.map(p.localToGeo) }
            }.value
            guard !Task.isCancelled else { return }
            polygons=output; shadowRevision += 1; updatingShadows=false
        }
    }
    private var departureLabel: String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier:"Asia/Dubai"); formatter.dateFormat = "h:mm a"
        return formatter.string(from:model.departure)
    }
    private func sunText(_ route: RouteOption) -> String {
        if model.loadingBuildings { return "Checking shade…" }
        if model.calculating { return "Updating shade…" }
        guard let e = route.exposure else { return "Shade not available here" }
        if e.samples.allSatisfy({ $0.solar.elevationDegrees <= 0 }) { return "After sunset · no direct sun" }
        return String(format:"Up to %.1f min sun",ceil(e.sunSeconds/6)/10)
    }
    /// Where a new report is pinned: your GPS fix when known, otherwise the spot you’re looking at.
    private var reportPoint:(coordinate:GeoPoint,description:String) {
        if let fix=location.lastFix,abs(fix.timestamp.timeIntervalSinceNow)<120,fix.horizontalAccuracy<100 { return (fix.coordinate.geo,"Your current location") }
        if let center=mapCenter.coordinate { return (center.geo,"Map center") }
        if model.hasOrigin { return (model.origin.geo,model.originName) }
        return (.init(latitude:25.20,longitude:55.27),"Dubai")
    }
    private func useLocation() {
        model.invalidate(); model.hasOrigin = false; model.usesCurrentLocation = true; location.request()
    }
    private func fit(_ route: RouteOption) {
        let coords = route.coordinates
        guard let first = coords.first else { return }
        var rect = MKMapRect(origin:MKMapPoint(first),size:.init(width:1,height:1))
        for coordinate in coords { rect = rect.union(MKMapRect(origin:MKMapPoint(coordinate),size:.init(width:1,height:1))) }
        position = .rect(rect.insetBy(dx:-max(rect.width*0.6,350),dy:-max(rect.height*0.85,350)))
    }
    @ViewBuilder private var activeMap:some View {
        #if canImport(GoogleMaps)
        if AppConfiguration.googleEnabled {
            GoogleRouteMap(routes:model.routes,selected:model.active?.id,origin:model.hasOrigin ? model.origin : nil,destination:model.hasDestination ? model.destination : nil,buildings:model.records,solar:model.routes.isEmpty ? nil : model.solar,shadowDistance:model.buffer,onHeadingChange:{ heading=$0 })
        } else { appleDisplayMap }
        #else
        appleDisplayMap
        #endif
    }
    @ViewBuilder private var appleDisplayMap:some View {
        if model.debug { map }
        else { BatchedRouteMap(routes:model.routes,selected:model.active?.id,origin:model.hasOrigin ? model.origin : nil,destination:model.hasDestination ? model.destination : nil,records:model.records,recordsRevision:model.recordsRevision,shadows:polygons,shadowsRevision:shadowRevision,exposureRevision:model.exposureRevision,hazards:reports.active,onHeadingChange:{ heading=$0 },onCenterChange:{ mapCenter.coordinate=$0 }) }
    }
    private var map: some View {
        Map(position:$position) {
            UserAnnotation()
            if model.hasOrigin { Marker(model.originName,systemImage:"figure.walk",coordinate:model.origin).tint(accent) }
            if model.hasDestination { Marker(model.destinationName,coordinate:model.destination).tint(.mint) }
            ForEach(reports.active) { report in Marker(report.hazard.rawValue,systemImage:report.hazard.icon,coordinate:report.coordinate.coordinate).tint(report.hazard.color) }
            ForEach(model.routes) { route in MapPolyline(coordinates:route.coordinates).stroke(route.id == model.active?.id ? accent : .gray.opacity(0.6),lineWidth:route.id == model.active?.id ? 7 : 4) }
            if !model.calculating,let exposure = model.active?.exposure {
                ForEach(Array(exposure.samples.enumerated()),id:\.offset) { index,value in
                    MapPolyline(coordinates:[value.sample.start,value.sample.end].map { model.projection.localToGeo($0).coordinate }).stroke(value.decision.directSun ? .orange : .green,style:StrokeStyle(lineWidth:7,lineCap:.round,lineJoin:.round))
                    if model.debug {
                        Annotation("Sample \(index)",coordinate:model.projection.localToGeo(value.sample.point).coordinate) {
                            Circle().fill(value.decision.directSun ? .orange : .green).frame(width:10,height:10).onTapGesture { model.selectedSample = index; settings = true }
                        }.annotationTitles(.hidden)
                    }
                }
            }
            if model.debug {
                ForEach(model.records,id:\.id) { building in
                    MapPolygon(coordinates:building.footprint.map(\.coordinate)).foregroundStyle(building.heightMeters == nil ? .red.opacity(0.3) : .white.opacity(0.2))
                    if heightLabels, let first = building.footprint.first {
                        Annotation(building.id,coordinate:first.coordinate) { Text(building.heightMeters.map { "\(Int($0))m \(building.heightSource?.rawValue ?? "?")" } ?? "Unknown height").font(.system(size:9)).padding(2).background(.regularMaterial) }.annotationTitles(.hidden)
                    }
                }
                if model.shadows {
                    ForEach(model.buildings,id:\.id) { b in
                        ForEach(Array(ShadeEngine(maximumSearchDistance:model.buffer).shadowQuads(building:b,solar:model.solar).enumerated()),id:\.offset) { _,quad in MapPolygon(coordinates:quad.map { model.projection.localToGeo($0).coordinate }).foregroundStyle(.purple.opacity(0.3)) }
                    }
                }
            }
        }.mapStyle(.standard(elevation:.flat,pointsOfInterest:.excludingAll))
    }
    private var debugSettings: some View {
        NavigationStack {
            Form {
                Section("Map provider") { Text(AppConfiguration.googleEnabled ? "Google Maps" : "Apple Maps · Google API keys not configured") }
                Section("About shade estimates") {
                    Text("Buildings are loaded on demand along routes across Dubai. Missing heights, complex buildings, and unavailable tiles limit shade estimates.")
                    Text("Some building heights are missing. Sun times are upper estimates using known buildings, not guaranteed exposure.").font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Demo mode",isOn:Binding(get:{ reports.demoMode },set:{ on in
                        if on { reports.plantDemoHazards(around:reportPoint.coordinate) } else { reports.clearDemoHazards() }
                    }))
                    if reports.demoMode {
                        ForEach(reports.demo) { r in
                            Button {
                                settings=false
                                DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { reports.simulateApproach(to:r) }
                            } label: {
                                Label { VStack(alignment:.leading) { Text("Walk into: \(r.summary)"); Text(r.hazard.rawValue).font(.caption).foregroundStyle(.secondary) } }
                                icon: { Image(systemName:r.hazard.icon).foregroundStyle(r.hazard.color) }
                            }
                        }
                    }
                } header: { Text("Demo") } footer: {
                    Text("Plants sample community hazards around you and lets you simulate stepping into a pin's 40 m trigger zone to see the Still there? prompt. Demo pins are never saved or shared.")
                }
                Section("Developer tools") {
                    Toggle("Debug shade on map",isOn:$model.debug)
                    if model.debug {
                        Toggle("Building heights",isOn:$heightLabels)
                        Toggle("Shadow overlay",isOn:$model.shadows)
                        Picker("Search radius",selection:$model.buffer) { Text("100 m").tag(100.0); Text("300 m").tag(300.0); Text("500 m").tag(500.0) }.onChange(of:model.buffer) { _,_ in Task { await model.load() } }
                        Text(String(format:"Azimuth %.1f° · elevation %.1f°",model.solar.azimuthDegrees,model.solar.elevationDegrees))
                        Text(model.status).font(.caption)
                        if let i = model.selectedSample, let e = model.active?.exposure, e.samples.indices.contains(i) { ShadeDebugView(index:i,value:e.samples[i]) }
                    }
                }
                Section { Link("© OpenStreetMap contributors",destination:URL(string:"https://www.openstreetmap.org/copyright")!) }
            }.navigationTitle("Map settings").toolbar { Button("Done") { settings = false } }
        }
    }
}
/// Reference holder so map panning doesn’t re-render the whole screen.
final class MapCenter { var coordinate:CLLocationCoordinate2D? }
struct ShadeDebugView: View {
    let index: Int
    let value: ClassifiedSample
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Sample \(index) · \(value.decision.directSun ? "SUN" : "NO DIRECT SUN")").bold()
            Text(value.decision.reason)
            Text(String(format:"Az %.1f° · El %.1f°",value.solar.azimuthDegrees,value.solar.elevationDegrees))
            if let d = value.decision.distanceMeters, let h = value.decision.buildingHeight, let r = value.decision.rayHeight { Text(String(format:"%@ · %.1fm away · building %.1fm > ray %.1fm",value.decision.buildingID ?? "",d,h,r)) }
        }.font(.caption).textSelection(.enabled)
    }
}
