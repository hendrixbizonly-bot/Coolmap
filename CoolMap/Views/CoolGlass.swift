import SwiftUI
extension View {
    @ViewBuilder func coolGlass()->some View {
        if #available(iOS 26.0,*) {
            self.glassEffect(.regular,in:RoundedRectangle(cornerRadius:28))
        } else {
            self.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:28))
                .overlay(RoundedRectangle(cornerRadius:28).stroke(.white.opacity(0.18)))
        }
    }
}
