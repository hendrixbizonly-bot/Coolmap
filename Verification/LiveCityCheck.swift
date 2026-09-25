import Foundation
@main struct LiveCityCheck {
    static func main() async {
        let route=[GeoPoint(latitude:25.2074,longitude:55.2637),GeoPoint(latitude:25.2014,longitude:55.2691)]
        let result=await CityBuildingProvider.shared.load(routes:[route],buffer:300)
        print("City Walk tile fetch:",result.completeFetch,"buildings:",result.records.count,"known heights:",result.records.filter{$0.heightMeters != nil}.count,result.note)
    }
}
