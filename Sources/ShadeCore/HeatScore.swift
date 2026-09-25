import Foundation
public enum SunIntensity {
    private static let peak = 205.97081264395823
    public static func weight(elevationDegrees: Double) -> Double {
        guard elevationDegrees.isFinite, elevationDegrees > 0 else { return 0 }
        let h = min(90,elevationDegrees)
        let projected = 0.308*cos(h*(0.998-h*h/50000) * .pi/180)
        let airMass = 1/(sin(h * .pi/180)+0.50572*pow(h+6.07995,-1.6364))
        let directNormal = 1353*pow(0.7,pow(airMass,0.678))
        return min(1,max(0,projected*directNormal/peak))
    }
}
public extension ShadeDecision {
    var sunFraction: Double { directSun ? 1 : 0 }
}
public enum RouteHeat {
    public static let defaultK = 2.0
    public static func cost(_ exposure: RouteExposure, expectedTravelTime: Double, k: Double = defaultK, fromDistance: Double = 0) -> Double {
        let total = exposure.samples.reduce(0) { $0+$1.sample.distanceFromPreviousSample }
        guard total > 0, expectedTravelTime.isFinite, expectedTravelTime > 0 else { return 0 }
        let cutoff = max(0,fromDistance)
        return exposure.samples.reduce(0) { cost,value in
            let length = value.sample.distanceFromPreviousSample
            let end = value.sample.distanceFromStart+length/2
            let remaining = min(length,max(0,end-cutoff))
            let seconds = expectedTravelTime*remaining/total
            return cost+seconds*(1+k*value.decision.sunFraction*SunIntensity.weight(elevationDegrees:value.solar.elevationDegrees))
        }
    }
}
