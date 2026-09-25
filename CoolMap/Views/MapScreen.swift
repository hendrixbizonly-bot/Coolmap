import SwiftUI
import MapKit

struct MapScreen:View {
    @StateObject private var model=AppModel()
    @StateObject private var location=LocationService()
    @ObservedObject private var reports=RouteReportStore.shared
    @State private var reporting=false
    @State private var mapCenter=MapCenter()
    private let expiryTicker=Timer.publish(every:60,on:.main,in:.common).autoconnect()
    @State private var searchOrigin:Bool?
    @State private var settings=false
    @State private var navigation=false
    @State private var minute=900.0
    @State private var playing=false
    @State private var scrubbing=false
    @State private var heading=0.0
    @State private var providerNotice=false
    @State private var shadePreferred=false
    @State private var polygons:[[GeoPoint]]=[]
    @State private var shadowRevision=0
    @State private var shadowTask:Task<Void,Never>?
    @State private var updatingShadows=false
    @AppStorage("mapProvider") private var provider="apple"
    private let ticker=Timer.publish(every:1,on:.main,in:.common).autoconnect()
    var body:some View {
        ZStack {
            if navigation { Color.black } else { activeMap.ignoresSafeArea() }
            if model.active != nil { sunBadge }
            VStack(spacing:12) {
                if model.hasDestination { endpoints } else { homeSearch }
                if model.busy { HStack { ProgressView(); Text("Finding your walk…") }.padding().coolGlass() }
                if model.routes.isEmpty && !model.busy && !model.status.isEmpty {
                    VStack(spacing:10) {
                        Text(model.status).font(.subheadline).multilineTextAlignment(.center)
                        Button("Change start") { searchOrigin=true }.font(.headline)
                        Button("Try Abu Dhabi demo") { Task { await model.demo() } }
                    }.padding().coolGlass()
                }
                if let verification=reports.verification,!navigation { StillThereCard(store:reports,report:verification) }
                Spacer(minLength:12)
                HStack { Spacer(); HazardReportButton { reporting=true } }
                if !model.hasDestination {
                    HStack { Spacer(); Button { useLocation() } label: { Image(systemName:"location.fill").font(.title2).padding(18) }.coolGlass().accessibilityLabel("Use current location") }
                    if let error=location.error { Text(error).font(.caption).padding().coolGlass() }
                }
                if model.active != nil { routeControls }
                else if !model.busy && model.hasDestination {
                    Button { Task { await model.demo() } } label: {
                        Label("Explore Abu Dhabi · demo walk",systemImage:"figure.walk").font(.headline).padding(18).frame(maxWidth:.infinity)
                    }.coolGlass()
                }
            }.padding(.horizontal,16).padding(.top,8).padding(.bottom,8)
        }.preferredColorScheme(.dark).tint(.cyan)
        .sheet(isPresented:Binding(get:{ searchOrigin != nil },set:{ if !$0 { searchOrigin=nil } })) {
            DestinationSearchView(isOrigin:searchOrigin == true,useLocation:{ searchOrigin=nil; useLocation() }) { item in
                if searchOrigin == true { model.chooseOrigin(item.placemark.coordinate,name:item.name ?? "Start") }
                else { model.chooseDestination(item.placemark.coordinate,name:item.name ?? "Destination") }
                searchOrigin=nil
                if !model.hasOrigin { useLocation() } else { Task { await model.load() } }
            }
        }
        .sheet(isPresented:$reporting) { HazardReportSheet(store:reports,coordinate:reportPoint.coordinate,locationDescription:reportPoint.description) }
        .onReceive(expiryTicker) { _ in reports.purgeExpired() }
        .onReceive(location.$coordinate) { coordinate in if let coordinate,!navigation { reports.checkProximity(to:coordinate.geo) } }
        .onChange(of:model.hasOrigin) { _,has in if has { Task { await reports.refresh(around:model.origin.geo) } } }
        .sheet(isPresented:$settings) { settingsView }
        .alert("Google Maps needs API keys",isPresented:$providerNotice) {
            Button("OK",role:.cancel) {}
        } message: { Text("Add Maps SDK and Routes/Places keys to Config/Local.xcconfig, then rebuild. Apple Maps is active until setup is complete.") }
        .fullScreenCover(isPresented:$navigation) {
            if let route=model.active { WalkingSessionView(route:route,location:location,destinationName:model.destinationName,routeColor:shadePreferred ? .blue : .yellow,stepFree:model.stepFree,barriers:model.stepFree ? model.barriers+model.reportBarriers : [],alternative:model.routes.first { $0.id != route.id && $0.id == (route.id == model.shortest ? model.shadeEstimate : model.shortest) } ?? model.routes.first { $0.id != route.id }) }
        }
        .onChange(of:model.departure) { _,_ in syncTime(); model.recalculate(); updateShadows() }
        .onChange(of:model.recordsRevision) { _,_ in updateShadows() }
        .onChange(of:model.exposureRevision) { _,_ in selectPreferredRoute() }
        .onDisappear { shadowTask?.cancel() }
        .onChange(of:minute) { _,_ in if !scrubbing { commitTime() } }
        .onChange(of:navigation) { _,opened in if opened { playing=false } }
        .onChange(of:model.routes.isEmpty) { _,empty in if empty { playing=false; shadePreferred=false }; syncTime() }
        .onReceive(ticker) { _ in if playing && !model.calculating && !model.loadingBuildings && !updatingShadows { minute=minute>=1435 ? 0 : min(1435,minute+15) } }
        .onReceive(location.$coordinate) { coordinate in
            guard let coordinate,model.usesCurrentLocation,!navigation else { return }
            model.chooseOrigin(coordinate,name:"Current location",current:true)
            if model.hasDestination { Task { await model.load() } }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--limit-test") {
                model.chooseOrigin(.init(latitude:24.4995,longitude:54.3888),name:"Al Maryah Island · limit test")
                model.chooseDestination(.init(latitude:24.5333,longitude:54.3987),name:"Louvre Abu Dhabi")
                await model.load()
            } else if ProcessInfo.processInfo.arguments.contains("--demo-autoload") { await model.demo() }
            else { model.status="" }
        }
    }
    private var homeSearch:some View {
        HStack(spacing:10) {
            Button { searchOrigin=false } label: {
                Label("Search for a destination",systemImage:"magnifyingglass")
                    .foregroundStyle(.white.opacity(0.85)).frame(maxWidth:.infinity,alignment:.leading).padding(18)
            }.coolGlass()
            Button { settings=true } label: { Image(systemName:"line.3.horizontal").font(.title2).padding(18) }.coolGlass()
                .accessibilityLabel("Menu")
        }
    }
    private var endpoints:some View {
        HStack(spacing:12) {
            VStack(spacing:0) {
                Button { searchOrigin=true } label: { inputRow(model.hasOrigin ? model.originName : "Current location",icon:"location.circle.fill",color:.cyan) }
                Divider().padding(.leading,32)
                Button { searchOrigin=false } label: { inputRow(model.hasDestination ? model.destinationName : "Where to?",icon:"mappin.circle.fill",color:.pink) }
            }
            VStack(spacing:15) {
                Button { Task { await model.swapEndpoints() } } label: { Image(systemName:"arrow.up.arrow.down") }.disabled(!model.hasDestination).accessibilityLabel("Swap start and destination")
                Button { model.invalidate(); model.hasDestination=false; playing=false } label: { Image(systemName:"xmark") }.accessibilityLabel("Close route")
            }.font(.title3).frame(width:32)
        }.padding(.horizontal,18).padding(.vertical,8).coolGlass()
    }
    private func inputRow(_ title:String,icon:String,color:Color)->some View {
        HStack(spacing:12) { Image(systemName:icon).foregroundStyle(color); Text(title).foregroundStyle(.white).lineLimit(1); Spacer(minLength:0) }.font(.body).frame(height:43).contentShape(Rectangle())
    }
    private var routeControls:some View {
        VStack(spacing:10) {
            VStack(alignment:.leading,spacing:4) {
                Toggle(isOn:$model.stepFree) {
                    Label("Step-free",systemImage:"figure.roll").font(.subheadline.bold())
                }.tint(Color(red:0.2,green:0.85,blue:0.6))
                if model.stepFree {
                    Text("Wheelchair & stroller friendly: avoids steps, raised kerbs and >8.3% slopes · slower pace ETA").font(.caption2).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal:false,vertical:true)
                }
            }.padding(.horizontal,12).padding(.vertical,8).coolGlass()
            HStack(spacing:8) {
                if let shortest=model.routes.first(where:{$0.id==model.shortest}) {
                    routePill(shortest,title:model.stepFree && shortest.id==model.bestStepFree ? (model.accessibility(shortest).isStepFree ? "Step-free" : "Fewest barriers") : "Shortest",color:model.stepFree && shortest.id==model.bestStepFree ? Color(red:0.2,green:0.85,blue:0.6) : .yellow,isShade:false)
                }
                if let shade=model.routes.first(where:{$0.id==model.shadeEstimate}),shade.id != model.shortest {
                    routePill(shade,title:model.stepFree && shade.id==model.bestStepFree ? (model.accessibility(shade).isStepFree ? "Step-free" : "Fewest barriers") : "Shade",color:model.stepFree && shade.id==model.bestStepFree ? Color(red:0.2,green:0.85,blue:0.6) : .blue,isShade:true)
                } else {
                    Text(model.loadingBuildings || model.calculating ? "Checking shade…" : "No shadier route found")
                        .font(.caption).frame(maxWidth:.infinity).padding(.vertical,17).coolGlass()
                }
            }
            if model.stepFree {
                if let active=model.active {
                    let a=model.accessibility(active)
                    Text(a.isStepFree ? "Step-free ✓"+(a.penaltySeconds>0 ? " · \(Int(a.penaltySeconds/60)) min slower for slope/surface" : "") : "⚠ \(a.blocking.count) barrier(s): "+a.blocking.prefix(2).map(\.detail).joined(separator:", "))
                        .font(.caption).foregroundStyle(a.isStepFree ? .green : .red).fixedSize(horizontal:false,vertical:true)
                    if !a.isStepFree { Text("No fully step-free route found — barriers are marked in red on the map.").font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
                }
            }
            HStack(spacing:10) {
                Button { playing.toggle() } label: { Image(systemName:playing ? "pause.fill" : "play.fill").frame(width:30,height:38) }.accessibilityLabel(playing ? "Pause sun simulation" : "Play sun simulation")
                Image(systemName:"sunrise.fill").foregroundStyle(.orange)
                Slider(value:$minute,in:0...1435,step:5,onEditingChanged:{ editing in scrubbing=editing; if editing { playing=false } else { commitTime() } }).accessibilityLabel("Time of day").accessibilityValue(timeLabel)
                Text(timeLabel).font(.headline.monospacedDigit()).foregroundStyle(.white)
                Image(systemName:"sunset.fill").foregroundStyle(.orange)
            }.padding(.horizontal,12).padding(.vertical,6).coolGlass()
            HStack {
                Text(model.loadingBuildings ? "Loading buildings…" : "Grey = shade · sun estimates").font(.caption2).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button { playing=false; navigation=true } label: { Label("Go",systemImage:"location.north.fill").font(.headline).padding(.horizontal,20).padding(.vertical,12) }.buttonStyle(.borderedProminent).tint(.blue)
            }
        }
    }
    private func routePill(_ route:RouteOption,title:String,color:Color,isShade:Bool)->some View {
        Button {
            shadePreferred=isShade
            model.selected=model.routes.firstIndex(where:{$0.id==route.id}) ?? 0
        } label: {
            VStack(spacing:3) {
              HStack(spacing:5) {
                Circle().fill(color).frame(width:7,height:7)
                Text(title).fontWeight(.semibold)
                Text("\(Int(ceil(model.eta(route)/60))) min").foregroundStyle(.white.opacity(0.8))
                          }
                if isShade,let shortest=model.routes.first(where:{$0.id==model.shortest}),route.id != shortest.id {
                    Text(String(format:"%+.0f%% walk time",(route.expectedTravelTime/shortest.expectedTravelTime-1)*100)).font(.caption2)
                }
                Text(model.calculating ? "Updating sun…" : route.exposure.map { String(format:"≈ %.1f min sun",$0.sunSeconds/60) } ?? "Sun estimate unavailable").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }.font(.subheadline).frame(maxWidth:.infinity).frame(height:68)
                .background(shadePreferred==isShade ? color.opacity(0.24) : .clear,in:Capsule())
                .overlay(Capsule().stroke(shadePreferred==isShade ? color : .white.opacity(0.2),lineWidth:1.5))
        }.buttonStyle(.plain).coolGlass().accessibilityLabel("\(title), \(Int(ceil(model.eta(route)/60))) minutes")
    }
    private var sunBadge:some View {
        GeometryReader { geometry in
            let sun=model.solar,angle=(sun.azimuthDegrees-heading)*Double.pi/180
            let radius=min(geometry.size.width,geometry.size.height)*0.35
            let point=CGPoint(x:geometry.size.width/2+sin(angle)*radius,y:min(geometry.size.height-290,max(160,geometry.size.height*0.48-cos(angle)*radius)))
            if sun.elevationDegrees>0 {
                SunRaysView(origin:point,target:CGPoint(x:geometry.size.width/2,y:geometry.size.height*0.40))
            }
            VStack(spacing:3) {
                Image(systemName:sun.elevationDegrees>0 ? "sun.max.fill" : "moon.fill").font(.title).foregroundStyle(sun.elevationDegrees>0 ? .orange : .gray).padding(12).coolGlass()
                Text(sun.elevationDegrees>0 ? "Alt \(Int(sun.elevationDegrees))°" : "Night").font(.caption.bold()).padding(5).background(.ultraThinMaterial,in:Capsule())
            }.position(point)
        }.allowsHitTesting(false)
    }
    @ViewBuilder private var activeMap:some View {
        #if canImport(GoogleMaps)
        if AppConfiguration.googleEnabled {
            GoogleRouteMap(routes:model.routes,selected:model.active?.id,origin:model.hasOrigin ? model.origin : nil,destination:model.hasDestination ? model.destination : nil,shadowPolygons:polygons,routeTint:shadePreferred ? .systemBlue : .systemYellow,onHeadingChange:{ heading=$0 })
        } else { appleMap }
        #else
        appleMap
        #endif
    }
    private var appleMap:some View {
        BatchedRouteMap(routes:model.routes,selected:model.active?.id,origin:model.hasOrigin ? model.origin : nil,destination:model.hasDestination ? model.destination : nil,shadows:polygons,shadowsRevision:shadowRevision,exposureRevision:model.exposureRevision,hazards:reports.active,barriers:model.stepFree ? model.barriers : [],onCenterChange:{ mapCenter.coordinate=$0 },routeTint:shadePreferred ? .systemBlue : .systemYellow,onHeadingChange:{ heading=$0 },floatingControls:true)
    }
    private var settingsView:some View {
        NavigationStack {
            Form {
                Section {
                    Label("Profile · coming soon",systemImage:"person.crop.circle").foregroundStyle(.secondary)
                    Button("Try Abu Dhabi demo") { settings=false; Task { await model.demo() } }
                }
                Section("Map") {
                    Button { provider="apple"; Task { await model.load() } } label: { Label("Apple Maps",systemImage:AppConfiguration.googleEnabled ? "map" : "checkmark") }
                    Button {
                        if AppConfiguration.googleAvailable { provider="google"; Task { await model.load() } }
                        else { providerNotice=true }
                    } label: { Label(AppConfiguration.googleAvailable ? "Google Maps" : "Google Maps · setup required",systemImage:AppConfiguration.googleEnabled ? "checkmark" : "map") }
                }
                Section("When are you walking?") {
                    DatePicker("Departure",selection:$model.departure).environment(\.timeZone,TimeZone(identifier:"Asia/Dubai")!)
                    Text("Abu Dhabi time · walks limited to one hour")
                }
                if let active=model.active,let heat=model.heatCost(for:active) {
                    Section("Route detail") {
                        Text(active.id==model.coolest ? "Lowest heat score among returned routes" : "Heat score")
                        Text(String(format:"%.0f solar-weighted cost",heat))
                    }
                }
                Section("About this preview") {
                    Text("Shortest compares distance. Shade compares estimated sun minutes among the returned routes. Missing building heights affect these estimates. Grey route segments have a known building blocking the sun. Yellow identifies Shortest; blue identifies Shade.")
                    Button("Restart Abu Dhabi demo") { settings=false; Task { await model.demo() } }
                    Link("© OpenStreetMap contributors",destination:URL(string:"https://www.openstreetmap.org/copyright")!)
                }
            }.navigationTitle("Map options").toolbar { Button("Done") { settings=false } }
        }
    }
    private func selectPreferredRoute() {
        if model.shadeEstimate==model.shortest { shadePreferred=false }
        let id=shadePreferred ? model.shadeEstimate : model.shortest
        if let index=model.routes.firstIndex(where:{$0.id==id}) { model.selected=index }
    }
    private func updateShadows() {
        shadowTask?.cancel()
        let projection=model.projection,engine=ShadeEngine(maximumSearchDistance:model.buffer)
        let buildings=model.buildings,solar=model.solar
        updatingShadows=true
        shadowTask=Task {
            do { try await Task.sleep(for:.milliseconds(120)) } catch { return }
            let output=await Task.detached(priority:.userInitiated) {
                buildings.flatMap { engine.shadowQuads(building:$0,solar:solar) }.map { $0.map(projection.localToGeo) }
            }.value
            guard !Task.isCancelled else { return }
            polygons=output; shadowRevision += 1; updatingShadows=false
        }
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
    private var reportPoint:(coordinate:GeoPoint,description:String) {
        if let fix=location.lastFix,abs(fix.timestamp.timeIntervalSinceNow)<120,fix.horizontalAccuracy<100 { return (fix.coordinate.geo,"Your current location") }
        if let center=mapCenter.coordinate { return (center.geo,"Map center") }
        if model.hasOrigin { return (model.origin.geo,model.originName) }
        return (.init(latitude:24.5005,longitude:54.3888),"Abu Dhabi")
    }
    private func useLocation() { model.invalidate(); model.hasOrigin=false; model.usesCurrentLocation=true; location.request() }
}

/// Reference holder avoids SwiftUI updates while the map pans.
final class MapCenter { var coordinate:CLLocationCoordinate2D? }
