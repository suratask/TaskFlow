import SwiftUI
import UIKit

enum TaskFlowTheme {
    // Match the system's inset-grouped list cells so remaining containers read as native sections.
    static var surface: Color { themedColor(base: .secondarySystemGroupedBackground, strength: 0.07) }
    static var insetSurface: Color { themedColor(base: .tertiarySystemGroupedBackground, strength: 0.10) }
    static func themedColor(base: UIColor, strength: CGFloat, theme: TaskRepository.AppTheme? = nil) -> Color {
        let selected = theme ?? (TaskRepository.AppTheme(rawValue: UserDefaults.standard.string(forKey: "TaskFlow.appTheme") ?? "") ?? .system)
        if selected == .system { return Color(uiColor: base) }
        return Color(uiColor: UIColor { traits in
            let original = base.resolvedColor(with: traits)
            let accent = UIColor(selected.primary).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            guard original.getRed(&r, green: &g, blue: &b, alpha: &a), accent.getRed(&ar, green: &ag, blue: &ab, alpha: &aa) else { return original }
            let amount = traits.userInterfaceStyle == .dark ? min(0.24, strength * 1.4) : strength
            return UIColor(red: r * (1 - amount) + ar * amount, green: g * (1 - amount) + ag * amount, blue: b * (1 - amount) + ab * amount, alpha: a)
        })
    }
    // MARK: Shape — one radius per role.
    /// Cards, tiles, board columns.
    static let cardRadius: CGFloat = 12
    /// Buttons, fields, thumbnails, and other controls inside a card.
    static let controlRadius: CGFloat = 10
    /// Large panels such as onboarding and capture surfaces.
    static let panelRadius: CGFloat = 18
    /// Badges, chips' inner marks, and small thumbnails.
    static let badgeRadius: CGFloat = 6
    static let border = Color.clear

    // MARK: Spacing — a 4-point scale.
    enum Spacing {
        static let xxSmall: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    // MARK: Semantic colors — meaning, not hue, so every screen agrees.
    static let overdue = Color.red
    static let success = Color.green
    static let warning = Color.orange
    static let flagged = Color.orange
    static let secondaryText = Color.secondary

    /// Due-date text color: red when overdue, otherwise secondary.
    static func dueColor(isOverdue: Bool) -> Color { isOverdue ? overdue : secondaryText }
}

extension View {
    /// The standard card: grouped surface and card radius.
    func taskFlowCard(padding: CGFloat = TaskFlowTheme.Spacing.medium) -> some View {
        self.padding(padding).background(TaskFlowTheme.surface, in: RoundedRectangle(cornerRadius: TaskFlowTheme.cardRadius, style: .continuous))
    }
}

/// The standard grouped background used by Settings, Reminders, and other system apps.
struct TaskFlowBackground: View {
    var accent: Color = .blue
    @AppStorage("TaskFlow.appTheme") private var themeName = TaskRepository.AppTheme.system.rawValue

    var body: some View {
        TaskFlowTheme.themedColor(base: .systemGroupedBackground, strength: 0.15, theme: TaskRepository.AppTheme(rawValue: themeName) ?? .system)
            .ignoresSafeArea()
    }
}

extension View {
    /// Lets the iOS 26 tab bar shrink while scrolling, as in Apple's apps. No effect on earlier versions.
    @ViewBuilder
    func minimizingTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}


private struct TaskFlowThemedBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(TaskFlowBackground())
    }
}
extension View {
    func taskFlowThemedBackground() -> some View { modifier(TaskFlowThemedBackgroundModifier()) }
}

/// Bottom toasts for the last undoable change ("Task completed · Undo", about 4 seconds)
/// and for errors (about 6 seconds). Neither blocks the screen the way an alert does.
struct StatusToastHost: View {
    @Bindable var repository: TaskRepository
    var bottomInset: CGFloat = TaskFlowTheme.Spacing.large
    @State private var visibleUndoID: UUID?
    @State private var shownError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: TaskFlowTheme.Spacing.small) {
            if let shownError {
                toast(icon: "exclamationmark.triangle.fill", tint: TaskFlowTheme.warning, text: shownError, actionTitle: nil, action: {}) {
                    dismissError()
                }
            }
            if let undo = repository.taskUndo, undo.id == visibleUndoID {
                toast(icon: "arrow.uturn.backward.circle.fill", tint: .accentColor, text: undo.message, actionTitle: "Undo", action: {
                    visibleUndoID = nil
                    Task { await repository.undoLastTaskAction() }
                }) { visibleUndoID = nil }
            }
        }
        .padding(.horizontal, TaskFlowTheme.Spacing.large)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: 560)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: visibleUndoID)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: shownError)
        .onChange(of: repository.taskUndo?.id) { _, id in visibleUndoID = id }
        .task(id: visibleUndoID) {
            guard visibleUndoID != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { visibleUndoID = nil }
        }
        .onChange(of: repository.errorMessage) { _, message in
            guard let message else { return }
            shownError = message
            AccessibilityNotification.Announcement(message).post()
        }
        .task(id: shownError) {
            guard shownError != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { dismissError() }
        }
    }

    private func dismissError() {
        if repository.errorMessage == shownError { repository.errorMessage = nil }
        shownError = nil
    }

    private func toast(icon: String, tint: Color, text: String, actionTitle: String?, action: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: TaskFlowTheme.Spacing.medium) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(.primary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, TaskFlowTheme.Spacing.large)
        .padding(.vertical, TaskFlowTheme.Spacing.medium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TaskFlowTheme.panelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}
