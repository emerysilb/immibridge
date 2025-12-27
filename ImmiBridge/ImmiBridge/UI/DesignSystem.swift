import SwiftUI

enum DesignSystem {
    enum Colors {
        static let windowBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
        static let cardBackground = Color(red: 0.18, green: 0.18, blue: 0.20)
        static let accentPrimary = Color.blue
        static let accentSecondary = Color.cyan
        static let success = Color.green
        static let textPrimary = Color.white
        static let textSecondary = Color.gray
        static let separator = Color.white.opacity(0.10)
    }

    enum Typography {
        static let header = Font.system(.title2, design: .rounded).bold()
        static let subHeader = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body, design: .default)
        static let captionMono = Font.system(size: 10, weight: .regular, design: .monospaced)
    }

    enum Shapes {
        static let cardCornerRadius: CGFloat = 16
        static let buttonCornerRadius: CGFloat = 8
        static let badgeCornerRadius: CGFloat = 12
    }
}

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            DesignSystem.Colors.windowBackground

            RadialGradient(
                colors: [
                    DesignSystem.Colors.accentPrimary.opacity(0.35),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 80,
                endRadius: 560
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [
                    DesignSystem.Colors.accentSecondary.opacity(0.28),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 70,
                endRadius: 520
            )
            .blendMode(.screen)

            LinearGradient(
                colors: [
                    Color.purple.opacity(0.14),
                    Color.clear
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .blendMode(.screen)

            Color.black.opacity(0.20)
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous)
                    .fill(DesignSystem.Colors.cardBackground.opacity(0.62))
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.38), radius: 22, x: 0, y: 14)
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 14)
            .background(isDestructive ? Color.red : DesignSystem.Colors.accentPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Shapes.buttonCornerRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(isDestructive ? Color.red : DesignSystem.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 14)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Shapes.buttonCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Shapes.buttonCornerRadius, style: .continuous)
                    .stroke(isDestructive ? Color.red.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
