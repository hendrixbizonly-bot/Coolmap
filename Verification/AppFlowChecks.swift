import Foundation
import MapKit
@main
struct AppFlowChecks {
    @MainActor static func main() async {
        let model = AppModel()
        precondition(!model.hasOrigin && !model.hasDestination && !model.debug)
        await model.load()
        precondition(model.routes.isEmpty && !model.busy)
        model.chooseDestination(.init(latitude:25.0794,longitude:55.1413),name:"Destination")
        precondition(model.hasDestination && !model.hasOrigin)
        model.chooseOrigin(.init(latitude:25.0777,longitude:55.1400),name:"My location",current:true)
        precondition(model.hasOrigin && model.usesCurrentLocation)
        model.routes = [RouteOption(routes:[])]
        model.busy = true
        model.chooseOrigin(.init(latitude:25.20,longitude:55.27),name:"New origin")
        precondition(model.routes.isEmpty && !model.busy && !model.usesCurrentLocation)
        precondition(model.hasDestination && model.destinationName == "Destination")
        model.routes = [RouteOption(routes:[])]
        model.chooseDestination(.init(latitude:25.21,longitude:55.28),name:"New destination")
        precondition(model.routes.isEmpty && model.destinationName == "New destination")
        print("PASS: clean launch, missing-origin guard, current-location selection, stale route invalidation, destination preservation, new-destination reset")
    }
}
