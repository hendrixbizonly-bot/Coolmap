#if canImport(GoogleMaps)
import SwiftUI
import GoogleMaps
import CoreLocation
struct GoogleRouteMap:UIViewRepresentable {
    let routes:[RouteOption]
    let selected:UUID?
    let origin:CLLocationCoordinate2D?
    let destination:CLLocationCoordinate2D?
    var shadowPolygons:[[GeoPoint]]=[]
    var buildings:[BuildingRecord]=[]
    var solar:SolarPosition?
    var shadowDistance=300.0
    var followCoordinate:CLLocationCoordinate2D?
    var heading=0.0
    var routeTint:UIColor = .systemBlue
    var navigationArrow=false
    var onHeadingChange:((Double)->Void)?
    func makeCoordinator()->Coordinator { Coordinator() }
    final class Coordinator:NSObject,GMSMapViewDelegate {
        var fittedID:String?
        var onHeadingChange:((Double)->Void)?
        func mapView(_ mapView:GMSMapView,didChange position:GMSCameraPosition) { onHeadingChange?(position.bearing) }
    }
    func makeUIView(context:Context)->GMSMapView {
        let options=GMSMapViewOptions()
        options.camera=GMSCameraPosition.camera(withLatitude:25.20,longitude:55.27,zoom:11)
        let map=GMSMapView(options:options)
        map.delegate=context.coordinator
        map.isMyLocationEnabled=true; map.settings.compassButton=true
        map.mapStyle=try? GMSMapStyle(jsonString:"""
        [{"elementType":"geometry","stylers":[{"color":"#1b2d43"}]},{"elementType":"labels.text.fill","stylers":[{"color":"#b5c6d5"}]},{"elementType":"labels.text.stroke","stylers":[{"color":"#142237"}]},{"featureType":"water","elementType":"geometry","stylers":[{"color":"#10213a"}]},{"featureType":"road","elementType":"geometry","stylers":[{"color":"#344b64"}]}]
        """)
        return map
    }
    func updateUIView(_ map:GMSMapView,context:Context) {
        context.coordinator.onHeadingChange=onHeadingChange
        map.clear()
        let projection=CoordinateProjection(origin:(origin ?? .init(latitude:24.5005,longitude:54.3888)).geo)
        if let solar {
            let engine=ShadeEngine(maximumSearchDistance:shadowDistance)
            for building in buildings {
                if let b=building.geometry(projection:projection) {
                    for quad in engine.shadowQuads(building:b,solar:solar) {
                        let shape=GMSPolygon(path:path(quad.map { projection.localToGeo($0).coordinate })); shape.fillColor=UIColor.black.withAlphaComponent(0.3); shape.strokeWidth=0; shape.map=map
                    }
                }
                let shape=GMSPolygon(path:path(building.footprint.map(\.coordinate))); shape.fillColor=UIColor.white.withAlphaComponent(0.15); shape.strokeWidth=0; shape.map=map
            }
        }
        for polygon in shadowPolygons {
            let shape=GMSPolygon(path:path(polygon.map(\.coordinate)))
            shape.fillColor=UIColor.black.withAlphaComponent(0.48); shape.strokeWidth=0; shape.map=map
        }
        for route in routes {
            let line=GMSPolyline(path:path(route.coordinates)); line.strokeColor=route.id==selected ? routeTint : .systemGray; line.strokeWidth=route.id==selected ? 6 : 3; line.map=map
            if route.id==selected,let exposure=route.exposure {
                for sample in exposure.samples {
                    let segment=GMSPolyline(path:path([sample.sample.start,sample.sample.end].map { projection.localToGeo($0).coordinate }))
                    segment.strokeColor=sample.solar.elevationDegrees<=0 || sample.decision.directSun ? routeTint : .systemGray; segment.strokeWidth=6; segment.map=map
                }
            }
        }
        if let origin { let marker=GMSMarker(position:origin); marker.title="Start"; marker.icon=GMSMarker.markerImage(with:.systemBlue); marker.map=map }
        if let destination { let marker=GMSMarker(position:destination); marker.title="Destination"; marker.map=map }
        if navigationArrow,let coordinate=followCoordinate ?? origin {
            let marker=GMSMarker(position:coordinate)
            let icon=UIImageView(image:UIImage(systemName:"location.north.circle.fill",withConfiguration:UIImage.SymbolConfiguration(pointSize:42,weight:.bold)))
            icon.tintColor = .systemBlue; icon.backgroundColor = .white; icon.layer.cornerRadius=21
            marker.iconView=icon; marker.isFlat=true; marker.rotation=heading; marker.groundAnchor=CGPoint(x:0.5,y:0.5); marker.zIndex=10; marker.map=map
        }
        if let followCoordinate {
            context.coordinator.fittedID=nil
            map.camera=GMSCameraPosition.camera(withTarget:followCoordinate,zoom:18,bearing:heading,viewingAngle:55)
        } else {
            let identity="\(selected?.uuidString ?? "none")-\(origin?.latitude ?? 0)-\(origin?.longitude ?? 0)"
            if context.coordinator.fittedID != identity {
                context.coordinator.fittedID=identity
                if let route=routes.first(where:{$0.id==selected}),let first=route.coordinates.first {
                    var bounds=GMSCoordinateBounds(coordinate:first,coordinate:first)
                    for coordinate in route.coordinates { bounds=bounds.includingCoordinate(coordinate) }
                    map.moveCamera(GMSCameraUpdate.fit(bounds,withPadding:60))
                } else if let origin { map.camera=GMSCameraPosition.camera(withTarget:origin,zoom:15) }
            }
        }
    }
    private func path(_ coordinates:[CLLocationCoordinate2D])->GMSMutablePath { let p=GMSMutablePath(); coordinates.forEach { p.add($0) }; return p }
}
#endif
