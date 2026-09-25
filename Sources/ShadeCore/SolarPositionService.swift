import Foundation
/// NOAA/Meeus solar coordinates; geometric center of sun, no atmospheric refraction.
/// Dates are absolute UTC instants. UI alone converts Asia/Dubai wall time.
public enum SolarPositionService {
    public static func position(at date: Date, coordinate: GeoPoint) -> SolarPosition {
        let rad = Double.pi/180
        func normalized(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360) }
        let t = (date.timeIntervalSince1970/86400 + 2440587.5 - 2451545)/36525
        let l = normalized(280.46646+t*(36000.76983+0.0003032*t))*rad
        let m = normalized(357.52911+t*(35999.05029-0.0001537*t))*rad
        let e = 0.016708634-t*(0.000042037+0.0000001267*t)
        let c = sin(m)*(1.914602-t*(0.004817+0.000014*t))+sin(2*m)*(0.019993-0.000101*t)+sin(3*m)*0.000289
        let omega = (125.04-1934.136*t)*rad
        let longitude = l+c*rad-0.00569*rad-0.00478*rad*sin(omega)
        let obliquity = (23+(26+(21.448-t*(46.815+t*(0.00059-t*0.001813)))/60)/60+0.00256*cos(omega))*rad
        let declination = asin(sin(obliquity)*sin(longitude))
        let y = pow(tan(obliquity/2),2)
        let equation = 4/rad*(y*sin(2*l)-2*e*sin(m)+4*e*y*sin(m)*cos(2*l)-0.5*y*y*sin(4*l)-1.25*e*e*sin(2*m))
        let utcSeconds = (date.timeIntervalSince1970.truncatingRemainder(dividingBy:86400)+86400).truncatingRemainder(dividingBy:86400)
        let solarMinutes = (utcSeconds/60+equation+4*coordinate.longitude+1440).truncatingRemainder(dividingBy:1440)
        let hourAngle = (solarMinutes/4-180)*rad, latitude = coordinate.latitude*rad
        let cosine = sin(latitude)*sin(declination)+cos(latitude)*cos(declination)*cos(hourAngle)
        let elevation = asin(min(1,max(-1,cosine)))/rad
        let azimuth = normalized(atan2(sin(hourAngle),cos(hourAngle)*sin(latitude)-tan(declination)*cos(latitude))/rad+180)
        return .init(azimuthDegrees:azimuth,elevationDegrees:elevation)
    }
}
