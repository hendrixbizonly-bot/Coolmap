import Foundation
import Combine
import Security

struct WalkerProfile: Decodable, Identifiable {
    let id: UUID
    let username: String
    let display_name: String
    let points: Int
    let created_at: String
}

struct WalkerPointEvent: Decodable, Identifiable {
    let id: Int
    let delta: Int
    let reason: String
    let created_at: String
}

struct CommunityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CommunityAPI {
    static func request(_ path: String, method: String = "GET", body: [String:Any]? = nil, token: String? = nil) async throws -> Data {
        guard AppConfiguration.sharedReportsEnabled else { throw CommunityError(message:"Community accounts aren’t connected in this build yet.") }
        let host=AppConfiguration.reportsHost
        guard host.range(of:"^[a-z0-9-]+\\.supabase\\.co$",options:.regularExpression) != nil,
              let url=URL(string:"https://\(host)/\(path)") else { throw CommunityError(message:"Community connection needs setup.") }
        var request=URLRequest(url:url); request.timeoutInterval=20; request.httpMethod=method
        request.setValue(AppConfiguration.reportsKey,forHTTPHeaderField:"apikey")
        if let token { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        if let body { request.httpBody=try JSONSerialization.data(withJSONObject:body); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await URLSession.shared.data(for:request)
        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let code=error?["code"] as? String ?? ""
            if code.hasPrefix("PGRST") || code=="42P01" { throw CommunityError(message:"Community database setup is incomplete. Apply the profile migration.") }
            let message=error?["message"] as? String ?? error?["error_description"] as? String ?? error?["msg"] as? String
            throw CommunityError(message:message ?? "Couldn’t connect to the community. Please try again.")
        }
        return data
    }

    static func date(_ value:String)->Date? {
        let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:value) ?? ISO8601DateFormatter().date(from:value)
    }
}

@MainActor
final class WalkerAccount: ObservableObject {
    static let shared=WalkerAccount()
    @Published private(set) var userID:UUID?
    @Published private(set) var profile:WalkerProfile?
    @Published private(set) var history:[WalkerPointEvent]=[]
    @Published private(set) var error:String?
    private var session:Session?
    private var refreshing:Task<Session,Error>?
    private var generation=UUID()

    private struct User:Codable { let id:UUID }
    private struct AuthReply:Decodable {
        let access_token:String,refresh_token:String
        let expires_in:Double
        let user:User
        var stored:Session { .init(accessToken:access_token,refreshToken:refresh_token,expiresAt:Date().addingTimeInterval(expires_in),user:user) }
    }
    private struct Session:Codable { let accessToken:String,refreshToken:String,expiresAt:Date,user:User }
    private var keychainQuery:[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.hendrix.coolmap.community",kSecAttrAccount as String:AppConfiguration.reportsHost]
    }
    init() {
        var query=keychainQuery; query[kSecReturnData as String]=true; query[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data,let saved=try? JSONDecoder().decode(Session.self,from:data) {
            session=saved; userID=saved.user.id
        }
    }
    var isSignedIn:Bool { userID != nil }

    func sendCode(email:String) async throws {
        _=try await CommunityAPI.request("auth/v1/otp",method:"POST",body:["email":email.trimmingCharacters(in:.whitespacesAndNewlines),"create_user":true])
    }
    func verifyCode(email:String,code:String) async throws {
        let data=try await CommunityAPI.request("auth/v1/verify",method:"POST",body:["email":email.trimmingCharacters(in:.whitespacesAndNewlines),"token":code.trimmingCharacters(in:.whitespacesAndNewlines),"type":"email"])
        let saved=try JSONDecoder().decode(AuthReply.self,from:data).stored
        try persist(saved); generation=UUID(); session=saved; userID=saved.user.id
        await refreshProfile()
    }
    func accessToken() async throws -> String {
        guard let saved=session else { throw CommunityError(message:"Sign in from Profile to share reports and check obstacles.") }
        if saved.expiresAt>Date().addingTimeInterval(60) { return saved.accessToken }
        let current=generation
        let task:Task<Session,Error>
        if let refreshing { task=refreshing }
        else {
            task=Task {
                let data=try await CommunityAPI.request("auth/v1/token?grant_type=refresh_token",method:"POST",body:["refresh_token":saved.refreshToken])
                return try JSONDecoder().decode(AuthReply.self,from:data).stored
            }
            refreshing=task
        }
        defer { if generation==current { refreshing=nil } }
        let refreshed=try await task.value
        guard generation==current else { throw CancellationError() }
        try persist(refreshed); session=refreshed
        return refreshed.accessToken
    }
    func refreshProfile() async {
        guard let id=userID else { return }
        let current=generation
        do {
            let token=try await accessToken()
            let data=try await CommunityAPI.request("rest/v1/walker_profiles?id=eq.\(id.uuidString)&select=*",token:token)
            let entries=try await CommunityAPI.request("rest/v1/walker_point_events?walker_id=eq.\(id.uuidString)&select=id,delta,reason,created_at&order=created_at.desc&limit=50",token:token)
            guard generation==current else { return }
            profile=try JSONDecoder().decode([WalkerProfile].self,from:data).first
            history=try JSONDecoder().decode([WalkerPointEvent].self,from:entries)
            error=profile==nil ? "Your profile hasn’t been created yet. Check the database setup." : nil
        } catch { if generation==current { self.error=error.localizedDescription } }
    }
    func updateName(_ name:String) async throws {
        guard let id=userID else { return }
        let cleaned=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...40).contains(cleaned.count) else { throw CommunityError(message:"Use a name between 1 and 40 characters.") }
        _=try await CommunityAPI.request("rest/v1/walker_profiles?id=eq.\(id.uuidString)",method:"PATCH",body:["display_name":cleaned],token:try await accessToken())
        await refreshProfile()
    }
    func signOut() async {
        let token=session?.accessToken
        generation=UUID(); refreshing?.cancel(); refreshing=nil
        SecItemDelete(keychainQuery as CFDictionary)
        session=nil; userID=nil; profile=nil; history=[]; error=nil
        if let token { _=try? await CommunityAPI.request("auth/v1/logout?scope=local",method:"POST",token:token) }
    }
    private func persist(_ session:Session) throws {
        let data=try JSONEncoder().encode(session)
        let updates=[kSecValueData as String:data] as CFDictionary
        let status=SecItemUpdate(keychainQuery as CFDictionary,updates)
        if status==errSecItemNotFound {
            var item=keychainQuery; item[kSecValueData as String]=data
            item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw CommunityError(message:"Couldn’t securely save your sign-in.") }; return
        }
        guard status==errSecSuccess else { throw CommunityError(message:"Couldn’t securely update your sign-in.") }
    }
}
