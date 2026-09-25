import SwiftUI
import PhotosUI

/// Waze-style persistent report control: always visible on the map, one tap opens the quick report sheet.
struct HazardReportButton: View {
    let action:()->Void
    var body:some View {
        Button(action:action) {
            ZStack(alignment:.bottomTrailing) {
                Image(systemName:"exclamationmark.triangle.fill")
                    .font(.system(size:26,weight:.bold))
                    .foregroundStyle(.black.opacity(0.85))
                Image(systemName:"plus.circle.fill")
                    .font(.system(size:16,weight:.bold))
                    .foregroundStyle(.white,.black.opacity(0.85))
                    .offset(x:6,y:4)
            }
            .frame(width:62,height:62)
            .background(Color(red:1,green:0.6,blue:0.1),in:Circle())
            .overlay(Circle().stroke(.white.opacity(0.25),lineWidth:1.5))
            .shadow(color:.black.opacity(0.4),radius:8,y:4)
        }
        .accessibilityLabel("Report a hazard")
        .accessibilityHint("Warn other walkers about a broken sidewalk, blocked crossing, missing shade or construction.")
    }
}

/// Waze-style “Still there?” card shown when the walker is within the trigger zone of an active pin.
/// Times out as a neutral event after a few seconds.
struct StillThereCard: View {
    @ObservedObject var store:RouteReportStore
    let report:RouteReport
    @State private var remaining=8.0
    private let tick=Timer.publish(every:0.1,on:.main,in:.common).autoconnect()
    private let panel=Color(red:0.055,green:0.09,blue:0.14)
    var body:some View {
        VStack(spacing:14) {
            HStack(spacing:12) {
                Image(systemName:report.hazard.icon).font(.title2).foregroundStyle(.black).frame(width:44,height:44).background(report.hazard.color,in:Circle())
                VStack(alignment:.leading,spacing:3) {
                    Text("Still there?").font(.headline)
                    Text("\(report.summary) · reported \(RelativeDateTimeFormatter().localizedString(for:report.date,relativeTo:Date()))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url=store.photoURL(report),let image=UIImage(contentsOfFile:url.path) {
                    Image(uiImage:image).resizable().scaledToFill().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:10))
                }
                Button { store.dismissVerification() } label: { Image(systemName:"xmark").font(.caption.bold()).padding(8).background(.white.opacity(0.1),in:Circle()) }.accessibilityLabel("Dismiss")
            }
            HStack(spacing:12) {
                Button { store.answerVerification(stillThere:true) } label: {
                    Label("Yes · still there",systemImage:"hand.thumbsup.fill").font(.subheadline.bold()).frame(maxWidth:.infinity).padding(.vertical,12)
                        .foregroundStyle(.white).background(Color(red:0.25,green:0.50,blue:1),in:RoundedRectangle(cornerRadius:14))
                }
                Button { store.answerVerification(stillThere:false) } label: {
                    Label("No · it’s gone",systemImage:"xmark.circle.fill").font(.subheadline.bold()).frame(maxWidth:.infinity).padding(.vertical,12)
                        .foregroundStyle(.black).background(Color(red:1,green:0.6,blue:0.1),in:RoundedRectangle(cornerRadius:14))
                }
            }.disabled(store.voting)
            if store.voting { ProgressView("Saving your check…") }
            if let error=store.verificationError { Text(error).font(.caption).foregroundStyle(.orange) }
            Text(store.demo.contains(where:{$0.id==report.id}) ? "Demo only · no real points" : "Reporter earns +5 for Yes or loses 2 for No. Only answer what you can see.").font(.caption2).foregroundStyle(.secondary)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.1)).overlay(alignment:.leading) { Capsule().fill(.white.opacity(0.5)).frame(width:g.size.width*remaining/8) }
            }.frame(height:3)
        }
        .padding(16).background(panel,in:RoundedRectangle(cornerRadius:22)).overlay(RoundedRectangle(cornerRadius:22).stroke(.white.opacity(0.12)))
        .shadow(color:.black.opacity(0.4),radius:12,y:6)
        .onReceive(tick) { _ in if !store.voting && store.verificationError==nil { remaining-=0.1; if remaining<=0 { store.dismissVerification() } } }
        .onChange(of:report.id) { _,_ in remaining=8 }
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Is the \(report.summary) still there?")
    }
}

/// One-tap crowd-sourced hazard reporting. Pick a hazard, it is pinned at your position immediately.
struct HazardReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store:RouteReportStore
    @ObservedObject private var account=WalkerAccount.shared
    @State private var profile=false
    let coordinate:GeoPoint
    let locationDescription:String
    @State private var picked:HazardCategory?
    @State private var note=""
    @State private var error:String?
    @State private var saving=false
    @State private var photoItem:PhotosPickerItem?
    @State private var photoData:Data?
    private let panel=Color(red:0.055,green:0.09,blue:0.14)
    private var columns:[GridItem] { Array(repeating:GridItem(.flexible(),spacing:14),count:2) }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("Pinned at \(locationDescription.lowercased()). \(account.isSignedIn ? "Shared reports can earn points when other walkers check them." : "Reports stay on this device until community sharing is available and you sign in.")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !account.isSignedIn { Button("Sign in to earn points") { profile=true } }
                    LazyVGrid(columns:columns,spacing:14) {
                        ForEach(HazardCategory.allCases) { hazard in
                            Button { picked = picked==hazard ? nil : hazard } label: {
                                VStack(spacing:10) {
                                    Image(systemName:hazard.icon).font(.system(size:30)).frame(height:36)
                                    Text(hazard.rawValue).font(.headline)
                                    Text(hazard.lifetimeLabel).font(.caption2).opacity(0.75)
                                }
                                .frame(maxWidth:.infinity).padding(.vertical,18)
                                .foregroundStyle(picked==hazard ? .black : .white)
                                .background(picked==hazard ? hazard.color : hazard.color.opacity(0.2),in:RoundedRectangle(cornerRadius:20))
                                .overlay(RoundedRectangle(cornerRadius:20).stroke(hazard.color,lineWidth:picked==hazard ? 0 : 1.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(picked==hazard ? .isSelected : [])
                        }
                    }
                    TextField("Add a note (optional)",text:$note,axis:.vertical)
                        .lineLimit(1...3).padding(14).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                    PhotosPicker(selection:$photoItem,matching:.images,photoLibrary:.shared()) {
                        HStack(spacing:12) {
                            if let photoData,let image=UIImage(data:photoData) {
                                Image(uiImage:image).resizable().scaledToFill().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:10))
                            } else {
                                Image(systemName:"camera.fill").frame(width:44,height:44).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
                            }
                            Text(photoData == nil ? "Add photo (optional)" : "Change photo").font(.subheadline)
                            Spacer()
                        }
                    }
                    .onChange(of:photoItem) { _,item in
                        Task { photoData=try? await item?.loadTransferable(type:Data.self) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Text("Community reports are unverified and don’t change routes or shade estimates.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(panel)
            .navigationTitle("Report a hazard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge:.bottom) {
                Button {
                    guard let picked else { return }
                    saving=true
                    Task {
                        do {
                            let report=RouteReport(category:picked.rawValue,note:note.trimmingCharacters(in:.whitespacesAndNewlines),coordinate:coordinate,date:Date(),locationDescription:locationDescription)
                            try await store.save(report)
                            if let photoData { store.attachPhoto(photoData,to:report.id) }
                            saving=false
                            if store.reports.first?.shared==true { dismiss() }
                            else { self.error=store.message ?? "Saved on this device."; self.picked=nil }
                        } catch { self.error="Couldn’t save the report. Please try again."; saving=false }
                    }
                } label: {
                    Text(picked.map { "Pin \($0.rawValue.lowercased())" } ?? "Choose a hazard")
                        .font(.headline).frame(maxWidth:.infinity).padding(.vertical,16)
                        .foregroundStyle(.black)
                        .background(picked==nil ? Color.gray.opacity(0.4) : Color(red:1,green:0.6,blue:0.1),in:RoundedRectangle(cornerRadius:18))
                }
                .disabled(picked==nil || saving)
                .padding(20).background(panel)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .sheet(isPresented:$profile) { WalkerProfileView() }
    }
}
