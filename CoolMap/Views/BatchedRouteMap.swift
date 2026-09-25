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
    var routeTint:UIColor = .systemBlue
    var onHeadingChange:((Double)->Void)?
    var floatingControls=false
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeUIView(context:Context)->MKMapView {
        let map=RouteFittingMapView()
        map.delegate=context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(.init(center:.init(latitude:24.5005,longitude:54.3888),latitudinalMeters:18000,longitudinalMeters:18000),animated:false)
        return map
    }
    func updateUIView(_ map:MKMapView,context:Context) {
        let c=context.coordinator
        if floatingControls {
            map.layoutMargins = .init(top:0,left:12,bottom:250,right:12)
            (map as? RouteFittingMapView)?.floatingControls=true
        }
        c.routeTint=routeTint
        c.onHeadingChange=onHeadingChange
        if c.recordsRevision != recordsRevision {
            c.recordsRevision=recordsRevision
            c.replace("buildings",on:map,with:records.isEmpty ? [] : [MKMultiPolygon(records.map { MKPolygon(coordinates:$0.footprint.map(\.coordinate),count:$0.footprint.count) })])
        }
        if c.shadowsRevision != shadowsRevision {
            c.shadowsRevision=shadowsRevision
            c.replace("shadows",on:map,with:shadows.isEmpty ? [] : [MKMultiPolygon(shadows.map { MKPolygon(coordinates:$0.map(\.coordinate),count:$0.count) })])
        }
        let routeKey=routes.map { $0.id.uuidString }.joined()+"\(selected?.uuidString ?? "")-\(exposureRevision)-\(routeTint.description)"
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
            map.removeAnnotations(map.annotations)
            for (name,coordinate) in [("Start",origin),("Finish",destination)] {
                if let coordinate { let pin=MKPointAnnotation(); pin.title=name; pin.coordinate=coordinate; map.addAnnotation(pin) }
            }
            if let route=routes.first(where:{$0.id==selected}),!route.coordinates.isEmpty {
                let label=RouteTimeAnnotation()
                label.coordinate=route.coordinates[route.coordinates.count/2]
                label.title="\(Int(ceil(route.expectedTravelTime/60))) min"
                map.addAnnotation(label)
                let rect=MKPolyline(coordinates:route.coordinates,count:route.coordinates.count).boundingMapRect
                (map as? RouteFittingMapView)?.routeRect=rect
                map.setVisibleMapRect(rect,edgePadding:.init(top:floatingControls ? 145 : 55,left:55,bottom:floatingControls ? 50 : 55,right:55),animated:false)
            } else if let origin { map.setRegion(.init(center:origin,latitudinalMeters:1800,longitudinalMeters:1800),animated:false) }
        }
    }
    final class Coordinator:NSObject,MKMapViewDelegate {
        var routeTint:UIColor = .systemBlue
        var recordsRevision:UUID?
        var shadowsRevision:Int?
        var routeKey="",fitKey=""
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
                let r:MKOverlayPathRenderer = key=="shadows" ? UnifiedShadowRenderer(overlay:multi) : MKMultiPolygonRenderer(multiPolygon:multi)
                r.fillColor=key=="shadows" ? UIColor.black.withAlphaComponent(0.48) : UIColor.white.withAlphaComponent(0.15)
                return r
            }
            let renderer:MKOverlayPathRenderer
            if let multi=overlay as? MKMultiPolyline { renderer=MKMultiPolylineRenderer(multiPolyline:multi) }
            else { renderer=MKPolylineRenderer(polyline:overlay as! MKPolyline) }
            renderer.strokeColor=key=="alternatives" ? .systemGray : key=="shade" ? .systemGray : routeTint
            renderer.lineWidth=key=="alternatives" ? 3 : key=="shade" ? 4 : 8
            renderer.lineCap = .round
            return renderer
        }
        func mapView(_ mapView:MKMapView,viewFor annotation:MKAnnotation)->MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            if annotation is RouteTimeAnnotation {
                let view=MKAnnotationView(annotation:annotation,reuseIdentifier:nil)
                let label=UILabel(frame:.init(x:0,y:0,width:70,height:32))
                label.text=annotation.title ?? ""; label.textAlignment = .center
                label.font = .boldSystemFont(ofSize:15); label.textColor = .white
                label.backgroundColor = routeTint; label.layer.cornerRadius=16; label.clipsToBounds=true
                view.frame=label.bounds; view.addSubview(label); view.centerOffset = .init(x:0,y:-25)
                return view
            }
            let view=mapView.dequeueReusableAnnotationView(withIdentifier:"endpoint") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation:annotation,reuseIdentifier:"endpoint")
            view.annotation=annotation
            view.markerTintColor=annotation.title=="Start" ? .systemBlue : .systemRed
            return view
        }
        func mapViewDidChangeVisibleRegion(_ mapView:MKMapView) {
            let heading=mapView.camera.heading
            guard !lastHeading.isFinite || abs(heading-lastHeading)>0.5 else { return }
            lastHeading=heading
            DispatchQueue.main.async { [weak self] in self?.onHeadingChange?(heading) }
        }
    }
}

/// Route controls change the available map height after a route loads.
private final class RouteFittingMapView:MKMapView {
    var routeRect:MKMapRect?
    var floatingControls=false
    private var previousSize=CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize,bounds.width>0,bounds.height>0 else { return }
        previousSize=bounds.size
        if let routeRect {
            setVisibleMapRect(routeRect,edgePadding:.init(top:floatingControls ? 145 : 40,left:55,bottom:floatingControls ? 50 : 40,right:55),animated:false)
        }
    }
}

private final class RouteTimeAnnotation:MKPointAnnotation {}

/// One nonzero fill keeps overlapping building shadows at a uniform opacity.
private final class UnifiedShadowRenderer: MKOverlayPathRenderer {
    override func createPath() {
        guard let multi=overlay as? MKMultiPolygon else { return }
        let combined=CGMutablePath()
        for polygon in multi.polygons {
            var vertices=(0..<polygon.pointCount).map { point(for:polygon.points()[$0]) }
            guard vertices.count>=3 else { continue }
            let area=vertices.indices.reduce(0.0) { value,index in
                let next=vertices[(index+1)%vertices.count],current=vertices[index]
                return value+current.x*next.y-next.x*current.y
            }
            if area<0 { vertices.reverse() }
            combined.addLines(between:vertices); combined.closeSubpath()
        }
        path=combined
    }
}
