import SwiftUI

/// Decorative sunlight only; ground shadows are calculated separately from building geometry.
struct SunRaysView: View {
    let origin: CGPoint
    let target: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/20,paused:reduceMotion)) { timeline in
            Canvas { context,size in
                let phase=reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let direction=atan2(target.y-origin.y,target.x-origin.x)
                let length=min(size.height*0.65,420)
                for index in 0..<5 {
                    let offset=Double(index-2)*0.12
                    let angle=direction+offset
                    let spread=0.035+Double(index%2)*0.018
                    var ray=Path()
                    ray.move(to:origin)
                    ray.addLine(to:CGPoint(x:origin.x+cos(angle-spread)*length,y:origin.y+sin(angle-spread)*length))
                    ray.addLine(to:CGPoint(x:origin.x+cos(angle+spread)*length,y:origin.y+sin(angle+spread)*length))
                    ray.closeSubpath()
                    let strength=0.065+0.015*sin(phase*0.8+Double(index))
                    context.fill(ray,with:.radialGradient(Gradient(colors:[.orange.opacity(strength),.yellow.opacity(strength*0.45),.clear]),center:origin,startRadius:12,endRadius:length))
                }
                let glow=CGRect(x:origin.x-90,y:origin.y-90,width:180,height:180)
                context.fill(Path(ellipseIn:glow),with:.radialGradient(Gradient(colors:[.yellow.opacity(0.40),.orange.opacity(0.15),.clear]),center:origin,startRadius:4,endRadius:90))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
