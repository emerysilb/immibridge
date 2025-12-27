import SwiftUI
#if os(macOS)
import AppKit
#endif

struct IconPlate: View {
    let systemName: String
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignSystem.Colors.accentPrimary)
        }
        .frame(width: size, height: size)
    }
}

struct SectionHeader: View {
    let systemName: String
    let title: String
    var trailing: AnyView? = nil

    init(systemName: String, title: String, trailing: AnyView? = nil) {
        self.systemName = systemName
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.accentPrimary)
            Text(title)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct StatusBadge: View {
    enum Kind {
        case success
        case info
        case muted
        case warning
    }

    let kind: Kind
    let text: String

    private var baseColor: Color {
        switch kind {
        case .success:
            return DesignSystem.Colors.success
        case .info:
            return DesignSystem.Colors.accentSecondary
        case .muted:
            return DesignSystem.Colors.textSecondary
        case .warning:
            return Color.yellow
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(baseColor)
                .frame(width: 12, height: 12)
            Text(text)
        }
        .font(.system(.caption, design: .rounded).bold())
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.10))
        .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))
        .clipShape(Capsule(style: .continuous))
    }
}

struct BackupCardView<Content: View>: View {
    let title: String
    let badge: StatusBadge
    let leadingIcon: AnyView?
    let isDisabled: Bool
    @ViewBuilder var content: () -> Content

    init(title: String, badge: StatusBadge, leadingIcon: AnyView? = nil, isDisabled: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.badge = badge
        self.leadingIcon = leadingIcon
        self.isDisabled = isDisabled
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                if let leadingIcon {
                    leadingIcon
                }
                Text(title)
                    .font(.system(.title, design: .rounded).bold())
                    .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.92))

                Spacer()

                badge
            }

            Divider()
                .overlay(DesignSystem.Colors.separator)

            content()
        }
        .padding(18)
        .cardBackground()
        .opacity(isDisabled ? 0.55 : 1)
    }
}

struct CollapsibleBottomDrawer<Content: View>: View {
    @Binding var isOpen: Bool
    var height: CGFloat = 280
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 42, height: 5)
                    .padding(.vertical, 10)
                Spacer()
                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)

            content()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous)
                .fill(DesignSystem.Colors.cardBackground.opacity(0.62))
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Shapes.cardCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.40), radius: 22, x: 0, y: 12)
        .offset(y: isOpen ? 0 : (height + 24))
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isOpen)
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
    }
}

struct LogConsoleView: View {
    let lines: [PhotoBackupViewModel.LogLine]
    let isActive: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(DesignSystem.Typography.captionMono)
                            .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: lines.last?.id) { lastID in
                guard isActive else { return }
                guard let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

#if os(macOS)
/// Transparent view that allows dragging the window (useful with `.windowStyle(.hiddenTitleBar)`).
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
#endif
