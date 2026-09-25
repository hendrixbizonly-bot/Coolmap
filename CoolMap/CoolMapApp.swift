import SwiftUI
@main
struct CoolMapApp: App {
    init() { AppConfiguration.initializeMaps() }
    var body: some Scene { WindowGroup { MapScreen() } }
}
