import SwiftUI

/// Compact contextual guidance, used below the form or setting it belongs to.
struct PIInlineMessage: View {
    let kind: PIStatusKind
    let text: String

    var body: some View {
        Label(text, systemImage: kind.icon)
            .font(PIFont.caption)
            .foregroundStyle(kind.tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

extension View {
    /// An actionable operation outcome. Unlike persistent connection or field
    /// guidance, failures and completed operations must not be stranded above
    /// a long form where the user cannot see them.
    func piMessageAlert(title: String, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { presented in
                    guard !presented, message.wrappedValue != nil else { return }
                    // SwiftUI performs the dismissal inside a view update. Clearing
                    // @Published/@State through this binding must happen afterwards.
                    DispatchQueue.main.async {
                        if message.wrappedValue != nil { message.wrappedValue = nil }
                    }
                }
            )
        ) {
            Button("知道了") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
