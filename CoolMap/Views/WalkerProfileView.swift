import SwiftUI

struct WalkerProfileView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account=WalkerAccount.shared
    @ObservedObject private var reports=RouteReportStore.shared
    @State private var email=""
    @State private var code=""
    @State private var codeSent=false
    @State private var name=""
    @State private var busy=false
    @State private var notice:String?
    @State private var preview=false
    private let refreshTimer=Timer.publish(every:20,on:.main,in:.common).autoconnect()

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:22) {
                    Toggle("Demo profile",isOn:$preview).tint(.cyan)
                    if preview { demoProfile } else if account.isSignedIn { signedIn } else { signIn }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading) }
                    VStack(alignment:.leading,spacing:12) {
                        Label("Your reports help other walkers",systemImage:"heart.circle.fill").font(.headline)
                        Text("When another walker checks your obstacle:").font(.subheadline)
                        rule("Yes · still there","+5 points",color:.cyan)
                        rule("No · it’s gone","−2 points",color:.orange)
                        Text("One check per walker per report. You can’t check your own reports. Skipping a check changes no points. Two No votes clear the pin. Demo checks never change real points.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(20).coolGlass()
                    if account.isSignedIn && !preview {
                        Button("Sign out",role:.destructive) { perform { await account.signOut() } }.disabled(busy)
                    }
                }.padding(20)
            }
            .background(Color(red:0.055,green:0.09,blue:0.14))
            .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .refreshable { await account.refreshProfile() }
            .task { preview=reports.demoMode; await account.refreshProfile(); name=account.profile?.display_name ?? "" }
            .onReceive(refreshTimer) { _ in if account.isSignedIn && !busy { Task { await account.refreshProfile() } } }
        }.preferredColorScheme(.dark).tint(.cyan)
    }
    private var demoProfile:some View {
        VStack(spacing:20) {
            VStack(spacing:12) {
                Label("DEMO · sample data",systemImage:"sparkles").font(.caption.bold()).foregroundStyle(.orange)
                Image(systemName:"person.crop.circle.fill").font(.system(size:70)).foregroundStyle(.cyan)
                Text("Alex · Community walker").font(.title2.bold())
                Text("@alex_walks").font(.subheadline).foregroundStyle(.secondary)
                Label("18",systemImage:"checkmark.shield.fill").font(.system(size:44,weight:.bold,design:.rounded)).foregroundStyle(.cyan)
                Text("COMMUNITY POINTS").font(.caption).foregroundStyle(.secondary)
                Text("4 confirmations · 1 report cleared").font(.subheadline)
            }.frame(maxWidth:.infinity).padding(24).coolGlass()
            VStack(alignment:.leading,spacing:16) {
                Label("Helpful walker",systemImage:"medal.fill").font(.headline).foregroundStyle(.cyan)
                Text("Points history").font(.headline)
                rule("Shade sail report confirmed","+5",color:.cyan)
                rule("Construction report confirmed","+5",color:.cyan)
                rule("Uneven paving report confirmed","+5",color:.cyan)
                rule("Missing canopy report confirmed","+5",color:.cyan)
                rule("Earlier obstacle is gone","−2",color:.orange)
                Text("Sample profile and history for the presentation. Demo reports and votes never change a real account’s points.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).coolGlass()
        }
    }
    private var signIn:some View {
        VStack(spacing:18) {
            Image(systemName:"person.crop.circle.fill").font(.system(size:70)).foregroundStyle(.cyan)
            Text("Build your walker profile").font(.title2.bold())
            Text("Keep your points and reports when you switch phones. Sign in with a code sent to your email.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !AppConfiguration.sharedReportsEnabled {
                Label("Community setup pending",systemImage:"network.slash").font(.headline)
                Text("This build isn’t connected to the shared database yet. Local reports are still available; shared profiles and points will work after setup.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Email",text:$email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(codeSent || busy).textFieldStyle(.roundedBorder)
                if codeSent {
                    TextField("Email code",text:$code).keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder)
                    Button("Verify & continue") {
                        perform {
                            try await account.verifyCode(email:email,code:code)
                            code=""; name=account.profile?.display_name ?? "Walker"
                            await reports.sync()
                        }
                    }.buttonStyle(.borderedProminent).disabled(busy || code.count<6)
                    Button("Use another email") { codeSent=false; code="" }.font(.caption).disabled(busy)
                } else {
                    Button("Send sign-in code") { perform { try await account.sendCode(email:email); codeSent=true; notice="Check your email for the sign-in code." } }
                        .buttonStyle(.borderedProminent).disabled(busy || !email.contains("@"))
                }
                if busy { ProgressView() }
            }
        }.padding(22).coolGlass()
    }
    private var signedIn:some View {
        VStack(spacing:20) {
            VStack(spacing:12) {
                Image(systemName:"person.crop.circle.fill").font(.system(size:64)).foregroundStyle(.cyan)
                Text(account.profile?.display_name ?? "Loading profile…").font(.title2.bold())
                Text("COMMUNITY POINTS").font(.caption).foregroundStyle(.secondary)
                Label(account.profile.map { String($0.points) } ?? "—",systemImage:"checkmark.shield.fill").font(.system(size:38,weight:.bold,design:.rounded)).foregroundStyle(.cyan)
                if let profile=account.profile {
                    Text("@\(profile.username)").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                    if let joined=CommunityAPI.date(profile.created_at) { Text("Joined \(joined.formatted(.dateTime.month(.wide).year()))").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth:.infinity).padding(24).coolGlass()
            if let error=account.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            HStack {
                TextField("Display name",text:$name).textContentType(.nickname).textFieldStyle(.roundedBorder)
                Button("Save") { perform { try await account.updateName(name); notice="Name updated." } }.disabled(busy || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            if reports.reports.contains(where:{ !$0.shared && $0.reporterID==account.userID }) {
                Button("Retry sharing pending reports") { perform { await reports.sync(); notice=reports.message } }.disabled(busy)
            }
            VStack(alignment:.leading,spacing:14) {
                Text("Points history").font(.headline)
                if account.history.isEmpty { Text("No points yet. Share an obstacle and points appear when another walker checks it.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(account.history) { entry in
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(entry.reason=="confirmed" ? "Your report was confirmed" : "Obstacle reported gone").font(.subheadline)
                            if let date=CommunityAPI.date(entry.created_at) { Text(date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(entry.delta>0 ? "+\(entry.delta)" : "\(entry.delta)").font(.headline).foregroundStyle(entry.delta>0 ? .cyan : .orange)
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(20).coolGlass()
        }
    }
    private func rule(_ label:String,_ amount:String,color:Color)->some View { HStack { Text(label); Spacer(); Text(amount).bold().foregroundStyle(color) }.font(.subheadline) }
    private func perform(_ action:@escaping () async throws->Void) {
        busy=true; notice=nil
        Task { defer { busy=false }; do { try await action() } catch { notice=error.localizedDescription } }
    }
}
