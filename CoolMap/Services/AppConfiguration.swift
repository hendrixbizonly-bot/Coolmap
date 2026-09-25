import Foundation
#if canImport(GoogleMaps)
import GoogleMaps
#endif
enum AppConfiguration {
    private static func value(_ key:String) -> String {
        let value=(Bundle.main.object(forInfoDictionaryKey:key) as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }
    static var mapsKey:String { value("GOOGLE_MAPS_API_KEY") }
    static var servicesKey:String { value("GOOGLE_SERVICES_API_KEY") }
    static var reportsHost:String { value("REPORTS_HOST") }
    static var reportsKey:String { value("REPORTS_PUBLIC_KEY") }
    static var sharedReportsEnabled:Bool { !reportsHost.isEmpty && !reportsKey.isEmpty }
    static var googleEnabled:Bool {
        #if canImport(GoogleMaps)
        !mapsKey.isEmpty && !servicesKey.isEmpty
        #else
        false
        #endif
    }
    static func initializeMaps() {
        #if canImport(GoogleMaps)
        if googleEnabled { GMSServices.provideAPIKey(mapsKey) }
        #endif
    }
}
