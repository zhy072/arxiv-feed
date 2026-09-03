import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let icon: String
}

/// Bottom-centre pill that confirms an action, then fades out.
struct ToastHost: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack {
            Spacer()
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.icon)
                    Text(toast.text)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}
