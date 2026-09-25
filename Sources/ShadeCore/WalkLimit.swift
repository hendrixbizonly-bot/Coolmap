import Foundation
public enum WalkLimit {
    public static func allows(seconds:Double)->Bool { seconds.isFinite && seconds>0 && seconds<=3600 }
}
