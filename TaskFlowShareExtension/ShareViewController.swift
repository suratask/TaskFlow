import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var sharedText = ""
    private let kindControl = UISegmentedControl(items: ["Task", "Event", "Note", "Read Later"])
    private static let readLaterIndex = 3
    private let preview = UILabel()
    private let save = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "TaskFlow"
        preview.numberOfLines = 4
        preview.font = .preferredFont(forTextStyle: .body)
        preview.textColor = .secondaryLabel
        kindControl.selectedSegmentIndex = 0

        let titleLabel = UILabel()
        titleLabel.text = "Capture in TaskFlow"
        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.textAlignment = .center
        save.isEnabled = false
        save.setTitle("Save Capture", for: .normal)
        save.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        save.addTarget(self, action: #selector(continueToApp), for: .touchUpInside)
        save.configuration = .borderedProminent()
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, kindControl, preview, save, cancel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            save.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        loadSharedText()
    }

    private func loadSharedText() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
            preview.text = "No selected text was provided."
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.url.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let text = (item as? String) ?? (item as? URL)?.absoluteString ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.sharedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.preview.text = self.sharedText.isEmpty ? "No text found." : self.sharedText
                self.save.isEnabled = !self.sharedText.isEmpty
                // A shared web page most likely belongs in a Reading list.
                if Self.webURL(in: self.sharedText) != nil, type == UTType.url.identifier { self.kindControl.selectedSegmentIndex = Self.readLaterIndex }
            }
        }
    }

    @objc private func continueToApp() {
        guard !sharedText.isEmpty,
              let defaults = UserDefaults(suiteName: "group.com.surratt.TaskFlow") else {
            extensionContext?.cancelRequest(withError: NSError(domain: "TaskFlowShare", code: 1))
            return
        }
        if kindControl.selectedSegmentIndex == Self.readLaterIndex, let url = Self.webURL(in: sharedText) {
            var links = defaults.stringArray(forKey: "TaskFlow.pendingReadingLinks") ?? []
            links.append(url.absoluteString)
            defaults.set(links, forKey: "TaskFlow.pendingReadingLinks")
        } else if kindControl.selectedSegmentIndex == 2 {
            var notes = defaults.array(forKey: "TaskFlow.pendingSharedNotes") as? [String] ?? []
            notes.append(sharedText)
            defaults.set(notes, forKey: "TaskFlow.pendingSharedNotes")
        } else {
            defaults.set(["text": sharedText, "kind": kindControl.selectedSegmentIndex == 1 ? "Event" : "Task"], forKey: "TaskFlow.pendingShareCapture")
        }
        defaults.synchronize()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// The first http(s) link in shared text, which may be a bare URL or text containing one.
    private static func webURL(in text: String) -> URL? {
        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    @objc private func cancelShare() {
        extensionContext?.cancelRequest(withError: NSError(domain: "TaskFlowShare", code: 2))
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
