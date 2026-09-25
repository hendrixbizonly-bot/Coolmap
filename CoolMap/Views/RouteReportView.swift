import SwiftUI
struct RouteReportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store=RouteReportStore()
    let coordinate:GeoPoint
    let locationDescription:String
    @State private var category="Blocked path"
    @State private var note=""
    @State private var error:String?
    @State private var saved=false
    var body:some View {
        NavigationStack {
            Form {
                if saved {
                    Section { Label(store.reports.first?.shared == true ? "Report shared" : "Saved to outbox",systemImage:"checkmark.circle.fill").foregroundStyle(.green); Text(store.message ?? "Saved") }
                } else {
                    Section("What did you find?") {
                        Picker("Problem",selection:$category) { ForEach(["Blocked path","Missing shade","Construction","No pavement","Other"],id:\.self) { Text($0) } }
                        TextField("Add a note (optional)",text:$note,axis:.vertical).lineLimit(3...6).onChange(of:note) { _,value in if value.count>1000 { note=String(value.prefix(1000)) } }
                    }
                    Section("Report location") { Text(locationDescription); Text(String(format:"%.5f, %.5f",coordinate.latitude,coordinate.longitude)).font(.caption).foregroundStyle(.secondary) }
                    Section { Text("When shared, the report’s location, category and note are visible to other walkers. Do not include personal details. Reports do not change routing or shade estimates.").font(.caption) }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button(AppConfiguration.sharedReportsEnabled ? "Share report" : "Save to outbox") { Task {
                        do { try await store.save(.init(category:category,note:note,coordinate:coordinate,date:Date(),locationDescription:locationDescription)); saved=true }
                        catch { self.error="Couldn’t save the report. Please try again." }
                    } }.disabled(store.sending)
                    if store.sending { ProgressView("Sending…") }
                }
                if !store.reports.isEmpty {
                    Section("Your saved reports") {
                        ForEach(store.reports) { report in VStack(alignment:.leading) { Text(report.category).bold(); Text(report.shared ? "Shared" : "Waiting to share").font(.caption); Text(report.note); Text(report.date,style:.date).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                if !store.nearby.isEmpty {
                    Section("Nearby community reports · unverified") {
                        ForEach(store.nearby) { report in VStack(alignment:.leading) { Text(report.category).bold(); Text(report.note); Text(report.date,style:.date).font(.caption) } }
                    }
                }
                if store.reports.contains(where:{ !$0.shared }) { Button("Retry sharing outbox") { Task { await store.sync() } }.disabled(store.sending) }
            }.task { await store.refresh(around:coordinate) }.navigationTitle("Route problem").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(.dark)
    }
}
