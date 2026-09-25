import SwiftUI
import MapKit
struct DestinationSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = SearchService()
    @State private var error: String?
    @State private var resolving = false
    @FocusState private var focused: Bool
    let isOrigin: Bool
    let useLocation: () -> Void
    let selected: (MKMapItem) -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                HStack {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField(isOrigin ? "Search starting point" : "Search destination",text:$search.query).focused($focused).autocorrectionDisabled()
                    if !search.query.isEmpty { Button { search.query = "" } label: { Image(systemName:"xmark.circle.fill") } }
                }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:14)).padding()
                List {
                    if isOrigin { Button(action:useLocation) { Label("Use my current location",systemImage:"location.fill") } }
                    if resolving { ProgressView("Finding place…") }
                    if let message = error ?? search.error { Text(message).foregroundStyle(.orange) }
                    if search.query.isEmpty {
                        Section("Explore Dubai") {
                            place("City Walk",subtitle:"Al Wasl · Dubai",latitude:25.2074,longitude:55.2637)
                            place("Burj Khalifa / Dubai Mall Metro",subtitle:"Downtown Dubai",latitude:25.2014,longitude:55.2691)
                            place("Dubai Marina Mall",subtitle:"Shopping centre · Dubai Marina",latitude:25.07698,longitude:55.14035)
                            place("Marina promenade",subtitle:"Walk by the water",latitude:25.0794,longitude:55.1413)
                        }
                    }
                    ForEach(search.results,id:\.self) { result in
                        Button { Task {
                            resolving = true; defer { resolving = false }
                            do {
                                if let item = try await search.resolve(result) { selected(item) }
                                else { error = "This place couldn’t be found. Try another result." }
                            } catch { self.error = "Couldn’t load this place. Please try again." }
                        } } label: {
                            HStack(spacing:12) {
                                Image(systemName:"mappin.circle").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment:.leading,spacing:5) { Text(result.title).foregroundStyle(.primary); Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical,5)
                        }.disabled(resolving)
                    }
                }.listStyle(.plain)
            }.navigationTitle(isOrigin ? "Starting point" : "Where to?").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() } }
                .onAppear { focused = true }
        }.preferredColorScheme(.dark)
    }
    private func place(_ name:String,subtitle:String,latitude:Double,longitude:Double) -> some View {
        Button {
            let item = MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:latitude,longitude:longitude))); item.name = name; selected(item)
        } label: { VStack(alignment:.leading,spacing:5) { Text(name); Text(subtitle).font(.caption).foregroundStyle(.secondary) } }
    }
}
struct WalkNavigationView: View {
    @Environment(\.dismiss) private var dismiss
    let route: RouteOption
    @ObservedObject var location: LocationService
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("\(Int(ceil(route.expectedTravelTime/60))) min walk · \(Int(route.distance)) m",systemImage:"figure.walk").font(.headline)
                    Text("All steps for this walk. Return to the map for GPS progress.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Walking directions") {
                    ForEach(Array(route.steps.enumerated()),id:\.offset) { index,step in
                        HStack(alignment:.top,spacing:14) {
                            Text("\(index+1)").font(.caption.bold()).frame(width:28,height:28).background(.blue.opacity(0.15),in:Circle())
                            VStack(alignment:.leading,spacing:6) {
                                Text(step.instructions)
                                if step.distance > 0 { Text("\(Int(step.distance)) m").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical,6)
                    }
                }
            }.navigationTitle("Walking directions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
