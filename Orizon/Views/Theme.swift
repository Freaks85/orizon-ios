import SwiftUI

/// Colours taken from aniverse.fr (dark background and the pink → purple logo gradient).
enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.035)     // #090909
    static let surface = Color(white: 0.11)
    static let surfaceHigh = Color(white: 0.16)
    static let pinkLight = Color(red: 0.965, green: 0.914, blue: 0.957)      // #F6E9F4
    static let pink = Color(red: 0.957, green: 0.690, blue: 0.753)           // #F4B0C0
    static let purple = Color(red: 0.678, green: 0.141, blue: 0.945)         // #AD24F1

    static let gradient = LinearGradient(
        colors: [pink, purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background {
                if prominent {
                    Capsule().fill(Theme.gradient)
                } else {
                    Capsule().fill(Theme.surfaceHigh)
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            trailing()
        }
        .padding(.horizontal)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

struct Badge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.gradient))
            .foregroundStyle(.white)
    }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.pink)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let retry {
                Button("Réessayer", action: retry)
                    .buttonStyle(PillButtonStyle())
                    .frame(width: 160)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

extension Int64 {
    var fileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Date {
    var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
