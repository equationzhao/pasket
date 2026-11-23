import SwiftUI

struct PasketFooterStatus<Status: View>: View {
    var center: PasketToastCenter
    var onAction: (PasketToast.Action) -> Void
    @ViewBuilder var status: () -> Status
    @Environment(\.pasketAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize?
    @State private var isHovered = false
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    var body: some View {
        let toast = center.current
        let detail = toast?.isBriefSuccess == false ? toast?.message : nil
        let hasDetail = detail != nil
        let usesGlass = appearance == .liquidGlass
        let rowHeight: CGFloat = usesGlass ? 26 : 28
        let inset: CGFloat = usesGlass ? 4 : 0
        let radius = hasDetail ? PasketShape.controlRadius + PasketShape.menuInset : rowHeight / 2 + inset
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        Group {
            if let toast {
                notification(toast, detail: detail, rowHeight: rowHeight, usesGlass: usesGlass)
                    .accessibilityElement(children: toast.isBriefSuccess ? .combine : .contain)
                    .accessibilityFocused($isAccessibilityFocused)
                    .accessibilityIdentifier(toast.isBriefSuccess ? "clipboardFooterSuccess" : "clipboardToast")
            } else {
                status().frame(height: rowHeight)
            }
        }
        .padding(inset)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            withAnimation(reduceMotion || size == nil ? nil : .smooth(duration: 0.26)) {
                size = newSize
            }
        }
        .frame(width: size?.width, height: size?.height, alignment: .topLeading)
        .clipShape(shape)
        .background {
            if toast != nil && !usesGlass {
                shape.fill(.primary.opacity(0.06))
            }
        }
        .glassEffect(usesGlass ? .regular : .identity, in: shape)
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: hasDetail)
        .onHover { isHovered = $0 }
        .modifier(PasketToastLifetime(toast: toast,
                                      isPaused: isHovered || isAccessibilityFocused,
                                      onDismiss: center.dismiss(id:)))
    }

    private func notification(_ toast: PasketToast, detail: String?, rowHeight: CGFloat, usesGlass: Bool) -> some View {
        let showsClose = toast.style != .success
        let trailingInset: CGFloat = showsClose ? 4 : 9
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: toast.style))
                    .foregroundStyle(tint(for: toast.style))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(toast.title)
                    .lineLimit(1)
                    .fixedSize()
                if detail == nil, let action = toast.action {
                    makeFinderButton(for: action, usesGlass: usesGlass)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, 9)
            .padding(.trailing, trailingInset + (showsClose ? PasketCloseButton.smallWidth + 6 : 0))
            .frame(height: rowHeight)

            if let detail {
                ToastDetailLayout(maxWidth: 300) {
                    HStack(spacing: 6) {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("clipboardFeedbackDetail")
                        if let action = toast.action {
                            makeFinderButton(for: action, usesGlass: usesGlass)
                        }
                    }
                    .padding(.leading, 29)
                    .padding(.trailing, 9)
                    .padding(.bottom, toast.action == nil ? 8 : 3)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsClose {
                PasketCloseButton(title: "Dismiss notification", help: "Dismiss notification", isInGlassGroup: usesGlass) {
                    center.dismiss(id: toast.id)
                }
                .controlSize(.small)
                .frame(height: rowHeight)
                .padding(.trailing, trailingInset)
                .accessibilityIdentifier("dismissClipboardFeedback")
            }
        }
    }

    private func makeFinderButton(for action: PasketToast.Action, usesGlass: Bool) -> some View {
        Button("Show in Finder") { onAction(action) }
            .buttonStyle(PasketButtonStyle(isProminent: true, isInGlassGroup: usesGlass))
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("showExportInFinder")
    }

    private func symbol(for style: PasketToast.Style) -> String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func tint(for style: PasketToast.Style) -> Color {
        switch style {
        case .success: .green
        case .information: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct ToastDetailLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let detail = subviews[0]
        let width = min(ceil(detail.sizeThatFits(.unspecified).width), maxWidth)
        let height = detail.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct PasketToastLifetime: ViewModifier {
    let toast: PasketToast?
    let isPaused: Bool
    let onDismiss: (UUID) -> Void
    @State private var shownID: UUID?
    @State private var remaining: Duration?
    @State private var deadline: ContinuousClock.Instant?

    private struct TimeoutIdentity: Equatable {
        let id: UUID?
        let isPaused: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: TimeoutIdentity(id: toast?.id, isPaused: isPaused)) {
                let clock = ContinuousClock()
                if shownID != toast?.id {
                    shownID = toast?.id
                    remaining = toast?.duration
                    deadline = nil
                }
                if isPaused {
                    if let deadline { remaining = max(.zero, clock.now.duration(to: deadline)) }
                    deadline = nil
                    return
                }
                guard let toast, let remaining else { return }
                let end = deadline ?? clock.now.advanced(by: remaining)
                deadline = end
                do {
                    try await clock.sleep(until: end)
                    try Task.checkCancellation()
                    onDismiss(toast.id)
                } catch {}
            }
            .onChange(of: toast?.id, initial: true) {
                if let toast {
                    AccessibilityNotification.Announcement([toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")).post()
                }
            }
    }
}
