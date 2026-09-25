import Foundation
public enum EncodedPolyline {
    public static func decode(_ encoded:String) -> [GeoPoint] {
        let bytes=Array(encoded.utf8); var index=0,latitude=0,longitude=0,points:[GeoPoint]=[]
        func next() -> Int? {
            var result=0,shift=0
            while index<bytes.count && shift<=30 {
                let b=Int(bytes[index])-63; index+=1
                guard b>=0 && b<=63 else { return nil }
                result |= (b & 31)<<shift; shift+=5
                if b<32 { return result & 1 != 0 ? ~(result>>1) : result>>1 }
            }
            return nil
        }
        while index<bytes.count {
            guard let dy=next(),let dx=next() else { return [] }
            latitude+=dy; longitude+=dx
            let p=GeoPoint(latitude:Double(latitude)*1e-5,longitude:Double(longitude)*1e-5)
            guard abs(p.latitude)<=90 && abs(p.longitude)<=180 else { return [] }
            points.append(p)
        }
        return points
    }
}
