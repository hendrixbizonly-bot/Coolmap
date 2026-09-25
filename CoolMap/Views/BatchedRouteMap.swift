import SwiftUI
import MapKit

/// Keep a single native map alive and replace only layers whose data changed.
struct BatchedRouteMap: UIViewRepresentable {
    let routes:[RouteOption]
    let selected:UUID?
    let origin:CLLocationCoordinate2D?
    let destination:CLLocationCoordinate2D?
    var records:[BuildingRecord]=[]
    var recordsRevision:UUID?
    var shadows:[[GeoPoint]]=[]
    var shadowsRevision=0
    var exposureRevision=0
    var hazards:[RouteReport]=[]
    var barriers:[AccessBarrier]=[]
    var onHeadingChange:((Double)->Void)?
    var onCenterChange:((CLLocationCoordinate2D)->Void)?
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeUIView(context:Context)->MKMapView {
        let map=RouteFittingMapView()
        map.delegate=context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(.init(center:.init(latitude:25.20,longitude:55.27),latitudinalMeters:18000,longitudinalMeters:18000),animated:false)
        return map
    }
    func updateUIView(_ map:MKMapView,context:Context) {
        let c=context.coordinator
        c.onHeadingChange=onHeadingChange
        c.onCenterChange=onCenterChange
        let hazardKey=hazards.map { "\($0.id.uuidString)@\($0.expiresAt.timeIntervalSinceReferenceDate)" }.joined()
        if c.hazardKey != hazardKey {
            c.hazardKey=hazardKey
            map.removeAnnotations(c.hazardPins)
            c.hazardPins=hazards.map(HazardAnnotation.init)
            map.addAnnotations(c.hazardPins)
        }
        let barrierKey=barriers.map { "\($0.id)@\($0.blocking)" }.joined()
        if c.barrierKey != barrierKey {
            c.barrierKey=barrierKey
            map.removeAnnotations(c.barrierPins)
            c.barrierPins=barriers.filter { $0.points.count<2 }.map(BarrierAnnotation.init)
            map.addAnnotations(c.barrierPins)
            c.replace("barriers",on:map,with:barriers.filter { $0.points.count>=2 }.map { barrier in
                let line=MKPolyline(coordinates:barrier.points.map(\.coordinate),count:barrier.points.count)
                line.title=barrier.blocking ? "barrier" : "barrier-slow"
                return line
            })
        }
        if c.recordsRevision != recordsRevision {
            c.recordsRevision=recordsRevision
            c.replace("buildings",on:map,with:records.isEmpty ? [] : [MKMultiPolygon(records.map { MKPolygon(coordinates:$0.footprint.map(\.coordinate),count:$0.footprint.count) })])
        }
        if c.shadowsRevision != shadowsRevision {
            c.shadowsRevision=shadowsRevision
            c.replace("shadows",on:map,with:shadows.isEmpty ? [] : [MKMultiPolygon(shadows.map { MKPolygon(coordinates:$0.map(\.coordinate),count:$0.count) })])
        }
        let routeKey=routes.map { $0.id.uuidString }.joined()+"\(selected?.uuidString ?? "")-\(exposureRevision)"
        if c.routeKey != routeKey {
            c.routeKey=routeKey
            for key in ["routes","alternatives","sun","shade","night"] { c.replace(key,on:map,with:[]) }
            for (active,key) in [(false,"alternatives"),(true,"routes")] {
                let lines=routes.filter { ($0.id==selected)==active }.map { MKPolyline(coordinates:$0.coordinates,count:$0.coordinates.count) }
                if !lines.isEmpty { c.replace(key,on:map,with:[MKMultiPolyline(lines)]) }
            }
            if let exposure=routes.first(where:{$0.id==selected})?.exposure,let origin {
                let p=CoordinateProjection(origin:origin.geo)
                let groups=RouteDisplayRun.make(exposure.samples)
                for (kind,key) in [(0,"night"),(1,"sun"),(2,"shade")] {
                    let lines=groups.filter { $0.kind==kind }.map { run in
                        let coords=run.points.map { p.localToGeo($0).coordinate }
                        return MKPolyline(coordinates:coords,count:coords.count)
                    }
                    if !lines.isEmpty { c.replace(key,on:map,with:[MKMultiPolyline(lines)]) }
                }
            }
        }
        let fitKey="\(selected?.uuidString ?? "")-\(origin?.latitude ?? 0)-\(origin?.longitude ?? 0)-\(destination?.latitude ?? 0)-\(destination?.longitude ?? 0)"
        if c.fitKey != fitKey {
            c.fitKey=fitKey
            map.removeAnnotations(map.annotations.filter { !($0 is HazardAnnotation) && !($0 is BarrierAnnotation) })
            for (name,coordinate) in [("Start",origin),("Finish",destination)] {
                if let coordinate { let pin=MKPointAnnotation(); pin.title=name; pin.coordinate=coordinate; map.addAnnotation(pin) }
            }
            if let route=routes.first(where:{$0.id==selected}),!route.coordinates.isEmpty {
                let rect=MKPolyline(coordinates:route.coordinates,count:route.coordinates.count).boundingMapRect
                (map as? RouteFittingMapView)?.routeRect=rect
                map.setVisibleMapRect(rect,edgePadding:.init(top:55,left:45,bottom:55,right:45),animated:false)
            } else if let origin { map.setRegion(.init(center:origin,latitudinalMeters:1800,longitudinalMeters:1800),animated:false) }
        }
    }
    final class Coordinator:NSObject,MKMapViewDelegate {
        var recordsRevision:UUID?
        var shadowsRevision:Int?
        var routeKey="",fitKey="",hazardKey="",barrierKey=""
        var hazardPins:[HazardAnnotation]=[]
        var barrierPins:[BarrierAnnotation]=[]
        var onCenterChange:((CLLocationCoordinate2D)->Void)?
        var layers:[String:[MKOverlay]]=[:]
        var onHeadingChange:((Double)->Void)?
        private var lastHeading=Double.nan
        func replace(_ key:String,on map:MKMapView,with overlays:[MKOverlay]) {
            map.removeOverlays(layers[key] ?? [])
            layers[key]=overlays
            map.addOverlays(overlays,level:key=="buildings" || key=="shadows" ? .aboveRoads : .aboveLabels)
        }
        func mapView(_ mapView:MKMapView,rendererFor overlay:MKOverlay)->MKOverlayRenderer {
            let key=layers.first { $0.value.contains { ($0 as AnyObject) === (overlay as AnyObject) } }?.key ?? "routes"
            if let multi=overlay as? MKMultiPolygon {
                let r=MKMultiPolygonRenderer(multiPolygon:multi)
                r.fillColor=key=="shadows" ? UIColor.black.withAlphaComponent(0.3) : UIColor.white.withAlphaComponent(0.15)
                return r
            }
            let renderer:MKOverlayPathRenderer
            if let multi=overlay as? MKMultiPolyline { renderer=MKMultiPolylineRenderer(multiPolyline:multi) }
            else { renderer=MKPolylineRenderer(polyline:overlay as! MKPolyline) }
            renderer.strokeColor=key=="alternatives" ? .systemGray : key=="sun" ? .systemOrange : key=="shade" ? .systemGreen : key=="barriers" ? .systemRed : .systemBlue
            renderer.lineWidth=key=="barriers" ? 5 : key=="alternatives" ? 4 : 6
            if let line=overlay as? MKPolyline,line.title=="barrier-slow" { renderer.lineDashPattern=[8,6] }
            renderer.lineCap = .round
            return renderer
        }
        func mapView(_ mapView:MKMapView,viewFor annotation:MKAnnotation)->MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            if let hazard=annotation as? HazardAnnotation {
                let view=mapView.dequeueReusableAnnotationView(withIdentifier:"hazard") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation:annotation,reuseIdentifier:"hazard")
                view.annotation=annotation
                view.markerTintColor=UIColor(hazard.report.hazard.color)
                view.glyphImage=UIImage(systemName:hazard.report.hazard.icon)
                view.canShowCallout=true
                view.displayPriority = .required
                if let url=RouteReportStore.shared.photoURL(hazard.report),let image=UIImage(contentsOfFile:url.path) {
                    let photo=UIImageView(image:image)
                    photo.frame=CGRect(x:0,y:0,width:120,height:90)
                    photo.contentMode = .scaleAspectFill
                    photo.clipsToBounds=true
                    view.detailCalloutAccessoryView=photo
                }
                return view
            }
            if let barrier=annotation as? BarrierAnnotation {
                let view=mapView.dequeueReusableAnnotationView(withIdentifier:"barrier") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation:annotation,reuseIdentifier:"barrier")
                view.annotation=annotation
                view.markerTintColor=barrier.barrier.kind == .elevator ? .systemPurple : .systemRed
                view.glyphImage=UIImage(systemName:barrier.barrier.kind.mapIcon)
                view.displayPriority = .required
                return view
            }
            let view=mapView.dequeueReusableAnnotationView(withIdentifier:"endpoint") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation:annotation,reuseIdentifier:"endpoint")
            view.annotation=annotation
            view.markerTintColor=annotation.title=="Start" ? .systemBlue : .systemRed
            return view
        }
        func mapViewDidChangeVisibleRegion(_ mapView:MKMapView) {
            DispatchQueue.main.async { [weak self] in self?.onCenterChange?(mapView.centerCoordinate) }
            let heading=mapView.camera.heading
            guard !lastHeading.isFinite || abs(heading-lastHeading)>0.5 else { return }
            lastHeading=heading
            DispatchQueue.main.async { [weak self] in self?.onHeadingChange?(heading) }
        }
    }
}

final class BarrierAnnotation:NSObject,MKAnnotation {
    let barrier:AccessBarrier
    init(barrier:AccessBarrier) { self.barrier=barrier }
    var coordinate:CLLocationCoordinate2D { barrier.points[0].coordinate }
    var title:String? { barrier.detail }
    var subtitle:String? { "barrier-\(barrier.kind.rawValue)" }
}
extension AccessBarrier.Kind {
    var mapIcon:String {
        switch self {
        case .steps: return "stairs"
        case .raisedKerb: return "figure.roll"
        case .steepIncline: return "arrow.up.right"
        case .roughSurface: return "square.grid.3x3"
        case .noWheelchair: return "nosign"
        case .elevator: return "arrow.up.and.down.square.fill"
        }
    }
}

final class HazardAnnotation:NSObject,MKAnnotation {
    let report:RouteReport
    init(report:RouteReport) { self.report=report }
    var coordinate:CLLocationCoordinate2D { report.coordinate.coordinate }
    var title:String? { report.hazard.rawValue }
    var subtitle:String? {
        let age=RelativeDateTimeFormatter().localizedString(for:report.date,relativeTo:Date())
        let left=report.expiresAt.timeIntervalSinceNow
        let clears=left<3600 ? "clears in \(max(1,Int(left/60))) min" : left<86400 ? "clears in \(Int(left/3600)) h" : "clears in \(Int(left/86400)) days"
        return [report.note.isEmpty ? nil : report.note,"Reported \(age) · \(clears)"].compactMap { $0 }.joined(separator:" — ")
    }
}

/// Route controls change the available map height after a route loads.
private final class RouteFittingMapView:MKMapView {
    var routeRect:MKMapRect?
    private var previousSize=CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize,bounds.width>0,bounds.height>0 else { return }
        previousSize=bounds.size
        if let routeRect {
            setVisibleMapRect(routeRect,edgePadding:.init(top:40,left:40,bottom:40,right:40),animated:false)
        }
    }
}
