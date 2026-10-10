import UIKit
import UniformTypeIdentifiers
import LinkPresentation

final class ShareViewController: UIViewController {
    private var sharedText = ""
    private let kindControl = UISegmentedControl(items: ["Task", "Event", "Note", "Read", "Watch"])
    private let preview = UILabel()
    private let titleField = UITextField()
    private let noteField = UITextField()
    private let destination = UIButton(type: .system)
    private let save = UIButton(type: .system)
    private var selectedListID = ""
    private var mediaKindWasEdited = false
    private var destinationWasEdited = false
    private var destinations: [[String: String]] = []
    private var metadataProvider: LPMetadataProvider?
    private let thumbnail = UIImageView()
    private var sharedURL: URL? { ReadingMedia.webURL(in: sharedText) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "TaskFlow"
        preview.numberOfLines = 2
        preview.font = .preferredFont(forTextStyle: .footnote)
        preview.textColor = .secondaryLabel
        kindControl.selectedSegmentIndex = 0
        // Calendar is optional in TaskFlow; with Calendars turned off in Settings, sharing can't make events.
        if UserDefaults(suiteName: "group.com.surratt.TaskFlow")?.object(forKey: "TaskFlow.usesCalendars") as? Bool == false {
            kindControl.setEnabled(false, forSegmentAt: 1)
        }
        kindControl.addTarget(self, action: #selector(userChangedKind), for: .valueChanged)
        titleField.placeholder = "Title (optional)"
        titleField.borderStyle = .roundedRect
        titleField.font = .preferredFont(forTextStyle: .body)
        noteField.placeholder = "Note (optional)"
        noteField.borderStyle = .roundedRect
        noteField.font = .preferredFont(forTextStyle: .body)
        destination.showsMenuAsPrimaryAction = true
        destination.contentHorizontalAlignment = .leading
        destinations = ReadingMedia.defaults.array(forKey: ReadingMedia.destinationsKey) as? [[String: String]] ?? []
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 8
        thumbnail.isHidden = true
        thumbnail.heightAnchor.constraint(equalToConstant: 100).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = "Save to TaskFlow"
        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        save.isEnabled = false
        save.setTitle("Save", for: .normal)
        save.configuration = .borderedProminent()
        save.addTarget(self, action: #selector(saveCapture), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        let explanation = UILabel()
        explanation.text = "Links are saved for import when TaskFlow opens. You can save before the preview loads."
        explanation.numberOfLines = 0
        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [titleLabel, kindControl, destination, thumbnail, titleField, preview, noteField, explanation, save, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            save.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        kindChanged()
        loadSharedText()
    }

    @objc private func userChangedKind() { mediaKindWasEdited = true; kindChanged() }

    @objc private func kindChanged() {
        let media = kindControl.selectedSegmentIndex >= 3
        destination.isHidden = !media
        let watch = kindControl.selectedSegmentIndex == 4
        let configured = ReadingMedia.defaults.string(forKey: ReadingMedia.preferenceKey(watch: watch)) ?? ""
        selectedListID = destinations.contains { $0["id"] == configured } ? configured : destinations.first?["id"] ?? ""
        updateDestination()
        updateSaveAvailability()
    }

    private func updateSaveAvailability() {
        let media = kindControl.selectedSegmentIndex >= 3
        save.isEnabled = !sharedText.isEmpty && (!media || sharedURL != nil)
    }

    private func updateDestination() {
        let name = destinations.first { $0["id"] == selectedListID }?["title"] ?? "Automatic Reading List"
        destination.setTitle("Save to: " + name + " ▾", for: .normal)
        destination.menu = UIMenu(children: destinations.compactMap { value in
            guard let id = value["id"], let title = value["title"] else { return nil }
            return UIAction(title: title, state: id == selectedListID ? .on : .off) { [weak self] _ in
                self?.selectedListID = id
                self?.destinationWasEdited = true
                self?.updateDestination()
            }
        })
    }

    private func loadSharedText() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let suppliedTitle = items.compactMap { $0.attributedTitle?.string }.first ?? ""
        Task { @MainActor [weak self] in
            var values = items.compactMap { $0.attributedContentText?.string }
            for provider in providers {
                for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    let value: String? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                            continuation.resume(returning: ReadingMedia.sharedText(from: item))
                        }
                    }
                    if let value { values.append(value) }
                }
            }
            guard let self else { return }
            self.sharedText = ReadingMedia.preferredShareText(values).trimmingCharacters(in: .whitespacesAndNewlines)
            self.preview.text = self.sharedText.isEmpty ? "No link or text was provided." : self.sharedText
            if (self.titleField.text ?? "").isEmpty { self.titleField.text = suppliedTitle }
            if let url = self.sharedURL {
                if !self.mediaKindWasEdited {
                    self.kindControl.selectedSegmentIndex = ReadingMedia.action(for: ReadingMedia.format(for: url)) == "Watch" ? 4 : 3
                    if !self.destinationWasEdited { self.kindChanged() }
                }
                self.fetchPreview(url)
            } else if !self.mediaKindWasEdited { self.kindChanged() }
            self.updateSaveAvailability()
        }
    }

    private func fetchPreview(_ url: URL) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        metadataProvider = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            DispatchQueue.main.async {
                guard let self, let metadata else { return }
                if !self.mediaKindWasEdited, let resolved = metadata.url, ReadingMedia.action(for: ReadingMedia.format(for: resolved)) == "Watch" {
                    self.kindControl.selectedSegmentIndex = 4
                    if !self.destinationWasEdited { self.kindChanged() }
                }
                if (self.titleField.text ?? "").isEmpty { self.titleField.text = metadata.title.map { ReadingMedia.cleanTitle($0, url: metadata.url ?? url) } }
                metadata.imageProvider?.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
                    DispatchQueue.main.async {
                        guard let self, let image = image as? UIImage else { return }
                        self.thumbnail.image = image
                        self.thumbnail.isHidden = false
                    }
                }
            }
        }
    }

    private var reviewedText: String {
        [titleField.text ?? "", sharedText, noteField.text ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    @objc private func saveCapture() {
        guard !sharedText.isEmpty else { return }
        save.isEnabled = false
        let defaults = ReadingMedia.defaults
        if kindControl.selectedSegmentIndex >= 3, let url = sharedURL {
            do {
                var capture = ReadingMedia.Capture(url: url.absoluteString, title: titleField.text ?? "", note: noteField.text ?? "", listID: selectedListID, watch: kindControl.selectedSegmentIndex == 4)
                if let image = thumbnail.image {
                    let ratio = min(1, 480 / max(image.size.width, image.size.height))
                    let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    if let data = preview.jpegData(compressionQuality: 0.75) { capture.previewFilename = ReadingMedia.storePreview(data, id: capture.id) }
                }
                try ReadingMedia.enqueue(capture)
            } catch {
                preview.text = "Unable to save the link. Please try again."
                save.isEnabled = true
                return
            }
        } else {
            do {
                let kind = kindControl.selectedSegmentIndex == 2 ? "Note" : kindControl.selectedSegmentIndex == 1 ? "Event" : "Task"
                try TextShareCapture(text: reviewedText, kind: kind).enqueue()
            } catch {
                preview.text = "Unable to save. Please try again."
                save.isEnabled = true
                return
            }
        }
        defaults.synchronize()
        metadataProvider?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc private func cancelShare() {
        metadataProvider?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: "TaskFlowShare", code: 2))
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
