import Foundation
enum RerouteService {
    static func decide(_ body:[String:Any]) async -> (prompt:Bool,reason:String,confidence:Double?)? {
        let base=AppConfiguration.rerouteURL.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard !base.isEmpty,let url=URL(string:base+"/api/reroute-decision") else { return nil }
        do {
            var request=URLRequest(url:url,timeoutInterval:8)
            request.httpMethod="POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try JSONSerialization.data(withJSONObject:body)
            let (data,response)=try await URLSession.shared.data(for:request)
            guard let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode),
                  let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let prompt=result["prompt"] as? Bool,let reason=result["reason"] as? String else { return nil }
            return (prompt,reason,result["confidence"] as? Double)
        } catch { return nil }
    }
}
