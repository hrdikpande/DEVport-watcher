import AppKit

/// Localised UI string (English is the key and the default). Strings live in Resources/Localizable.xcstrings.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

/// A confirmation or question shown inline in the panel (no modal alert that steals focus). When the panel
/// isn't open (a notification action, the hot key while closed) it falls back to an alert.
struct InlinePrompt: Identifiable {
    enum Role { case normal, destructive, cancel }
    struct Button {
        let title: String
        let role: Role
        let action: (String) -> Void       // receives the text field's value ("" without one)
    }
    let id = UUID()
    let title: String
    let message: String
    var buttons: [Button]
    var field: (placeholder: String, initial: String)? = nil
    var image: NSImage? = nil
    var key: String? = nil                  // the stop flow this prompt belongs to (one per process)
}

@MainActor
final class Prompter {
    /// Shows a prompt inline when the panel is visible; returns false to fall back to an alert.
    var showInline: (InlinePrompt) -> Bool = { _ in false }

    func ask(_ p: InlinePrompt) {
        if showInline(p) { return }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = p.title
        a.informativeText = p.message
        a.alertStyle = p.buttons.contains { $0.role == .destructive } ? .warning : .informational
        var field: NSTextField?
        if let f = p.field {
            let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            t.placeholderString = f.placeholder
            t.stringValue = f.initial
            a.accessoryView = t
            a.window.initialFirstResponder = t
            field = t
        } else if let image = p.image {
            let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
            v.image = image
            v.imageScaling = .scaleProportionallyUpOrDown
            a.accessoryView = v
        }
        let ordered = p.buttons.filter { $0.role != .cancel } + p.buttons.filter { $0.role == .cancel }
        for b in ordered {
            let button = a.addButton(withTitle: b.title)
            button.hasDestructiveAction = b.role == .destructive
            if b.role == .cancel { button.keyEquivalent = "\u{1b}" }
        }
        let i = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if i >= 0 && i < ordered.count { ordered[i].action(field?.stringValue ?? "") }
    }

    func tell(_ title: String, _ message: String = "") {
        ask(InlinePrompt(title: title, message: message, buttons: [.init(title: L("OK"), role: .cancel, action: { _ in })]))
    }

    func confirm(_ title: String, _ message: String, button: String, destructive: Bool = true, key: String? = nil,
                 onCancel: @escaping () -> Void = {}, _ yes: @escaping () -> Void) {
        var p = InlinePrompt(title: title, message: message, buttons: [
            .init(title: button, role: destructive ? .destructive : .normal, action: { _ in yes() }),
            .init(title: L("Cancel"), role: .cancel, action: { _ in onCancel() }),
        ])
        p.key = key
        ask(p)
    }

    func input(_ title: String, _ message: String, placeholder: String = "", initial: String = "", button: String = L("Continue"),
               onCancel: @escaping () -> Void = {}, _ done: @escaping (String) -> Void) {
        var p = InlinePrompt(title: title, message: message, buttons: [
            .init(title: button, role: .normal, action: { done($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
            .init(title: L("Cancel"), role: .cancel, action: { _ in onCancel() }),
        ])
        p.field = (placeholder, initial)
        ask(p)
    }
}
