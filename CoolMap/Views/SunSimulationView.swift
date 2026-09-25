import SwiftUI
import MapKit
struct SunSimulationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model:AppModel
    @ObservedObject var location:LocationService
    @State private var minute=960.0
    @State private var playing=false
    @State private var navigating=false
    @State private var position=MapCameraPosition.automatic
    @State private var heading=0.0
    @State private var polygons:[[GeoPoint]]=[]
    @State private var shadowRevision=0
    @State private var shadowTask:Task<Void,Never>?
    @State private var updatingShadows=false
    @State private var scrubbing=false
    private let ticker=Timer.publish(every:0.8,on:.main,in:.common).autoconnect()
    private let panel=Color(red:0.055,green:0.09,blue:0.14)
    private var sun:SolarPosition { model.solar }
    var body:some View {
        ZStack {
            activeMap
            GeometryReader { geometry in
                let angle=(sun.azimuthDegrees-heading)*Double.pi/180
                let radius=max(35,min(geometry.size.width,geometry.size.height)*0.34)
                VStack(spacing:4) {
                    Image(systemName:sun.elevationDegrees>0 ? "sun.max.fill" : "moon.fill").font(.title).foregroundStyle(sun.elevationDegrees>0 ? .orange : .gray)
                        .padding(12).background(panel.opacity(0.9),in:Circle()).shadow(color:.orange.opacity(sun.elevationDegrees>0 ? 0.5 : 0),radius:18)
                    Text(sun.elevationDegrees>0 ? "Alt \(Int(sun.elevationDegrees))°" : "Below horizon").font(.caption.bold()).padding(5).background(panel,in:Capsule())
                }.position(x:geometry.size.width/2+sin(angle)*radius,y:geometry.size.height/2-cos(angle)*radius)
                    .accessibilityLabel("Sun azimuth \(Int(sun.azimuthDegrees)) degrees, elevation \(Int(sun.elevationDegrees)) degrees")
            }.allowsHitTesting(false)
        }
        .safeAreaInset(edge:.top) {
            HStack {
                VStack(alignment:.leading,spacing:5) { Text("Sun & shade preview").font(.headline); Text(model.destinationName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Button("Close") { playing=false; dismiss() }
            }.padding().background(panel)
        }
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:12) {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack {
                        ForEach(Array(model.routes.enumerated()),id:\.element.id) { index,route in
                            Button { model.selected=index; fit() } label: {
                                VStack(alignment:.leading,spacing:4) {
                                    Text("\(route.id == model.fastest ? "Fastest" : "Alternative") · \(Int(ceil(route.expectedTravelTime/60))) min").font(.subheadline.bold())
                                    Text(model.calculating ? "Updating shade…" : route.exposure.map { String(format:"Up to %.1f min sun",ceil($0.sunSeconds/6)/10) } ?? "Shade data unavailable").font(.caption)
                                }.padding(12).background(model.selected == index ? Color.blue : panel,in:Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button { playing.toggle() } label: { Image(systemName:playing ? "pause.fill" : "play.fill").frame(width:36,height:36) }.accessibilityLabel(playing ? "Pause sun simulation" : "Play sun simulation")
                    Image(systemName:"sunrise.fill").foregroundStyle(.orange)
                    Slider(value:$minute,in:0...1435,step:5,onEditingChanged: { editing in
                        scrubbing=editing
                        if editing { playing=false } else { commitTime() }
                    }).accessibilityLabel("Time of day").accessibilityValue(timeLabel)
                    Image(systemName:"sunset.fill").foregroundStyle(.orange)
                    Text(timeLabel).font(.headline.monospacedDigit()).frame(width:55)
                }
                HStack {
                    DatePicker("Date",selection:$model.departure,displayedComponents:.date).labelsHidden().environment(\.timeZone,TimeZone(identifier:"Asia/Dubai")!)
                    Text("Dubai time").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.calculating { ProgressView().accessibilityLabel("Updating shade") }
                }
                Text(model.loadingBuildings ? "Loading buildings along your walk…" : model.records.isEmpty ? "No building data available. The sun position is still calculated." : "Estimated shadows · missing building heights may leave gaps").font(.caption).foregroundStyle(.secondary)
                Button { playing=false; navigating=true } label: { Label("Start walk",systemImage:"location.north.fill").font(.headline).frame(maxWidth:.infinity).padding(14) }.buttonStyle(.borderedProminent)
            }.padding(16).background(panel)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"Asia/Dubai")!
            minute=Double(calendar.component(.hour,from:model.departure)*60+calendar.component(.minute,from:model.departure))
            updateShadows(); fit()
        }
        .onChange(of:minute) { _,_ in
            if !scrubbing { commitTime() }
        }
        .onChange(of:model.departure) { _,_ in updateShadows() }
        .onChange(of:model.recordsRevision) { _,_ in updateShadows() }
        .onReceive(ticker) { _ in if playing && !model.calculating && !updatingShadows { minute = minute>=1435 ? 0 : min(1435,minute+15) } }
        .onDisappear { playing=false; shadowTask?.cancel() }
        .fullScreenCover(isPresented:$navigating) { if let route=model.active { WalkingSessionView(route:route,location:location,destinationName:model.destinationName) } }
    }
    private var timeLabel:String { String(format:"%02d:%02d",Int(minute)/60,Int(minute)%60) }
    @ViewBuilder private var activeMap:some View {
        #if canImport(GoogleMaps)
        if AppConfiguration.googleEnabled {
            GoogleRouteMap(routes:model.routes,selected:model.active?.id,origin:model.origin,destination:model.destination,buildings:model.records,solar:sun,shadowDistance:model.buffer,onHeadingChange:{ heading=$0 })
        } else { simulationMap }
        #else
        simulationMap
        #endif
    }
    private var simulationMap:some View {
        BatchedRouteMap(routes:model.routes,selected:model.active?.id,origin:model.origin,destination:model.destination,
                        records:model.records,recordsRevision:model.recordsRevision,shadows:polygons,
                        shadowsRevision:shadowRevision,exposureRevision:model.exposureRevision,onHeadingChange:{ heading=$0 })
    }
    private func commitTime() {
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"Asia/Dubai")!
        model.departure=calendar.date(bySettingHour:Int(minute)/60,minute:Int(minute)%60,second:0,of:model.departure)!
    }
    private func updateShadows() {
        shadowTask?.cancel()
        let p=model.projection,engine=ShadeEngine(maximumSearchDistance:model.buffer),buildings=model.buildings,solar=sun
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
    private func fit() {
        guard let route=model.active,let first=route.coordinates.first else { return }
        var rect=MKMapRect(origin:MKMapPoint(first),size:.init(width:1,height:1))
        for c in route.coordinates { rect=rect.union(.init(origin:MKMapPoint(c),size:.init(width:1,height:1))) }
        position = .rect(rect.insetBy(dx:-max(400,rect.width*0.25),dy:-max(400,rect.height*0.25)))
    }
}
