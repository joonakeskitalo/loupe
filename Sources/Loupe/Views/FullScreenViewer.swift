import SwiftUI

/// macOS equivalent of a full-screen cover: overlays the content on top of the
/// window with a transition, since SwiftUI's `fullScreenCover` is iOS-only.
extension View {
    func fullScreenViewer<ViewerContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> ViewerContent
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                content()
                    .zIndex(1)
            }
        }
    }
}
