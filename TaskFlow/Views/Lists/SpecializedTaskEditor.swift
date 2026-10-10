import CryptoKit
import ImageIO
import QuickLook
import MapKit
import SwiftUI
import TipKit

struct SpecializedTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var repository: TaskRepository
    let task: TaskItem
    let type: SpecializedListType
    @State private var details = SpecializedTaskDetails()
    @State private var saving = false
    @State private var initialized = false
    @State private var mediaTitle = ""
    @State private var mediaNote = ""
    @State private var mediaTags = ""
    @State private var mediaLinks: [EditableMediaLink] = []
    @State private var location: TaskLocation?
    @State private var originalLocation: TaskLocation?
    @State private var locationQuery = ""
    @State private var locationResults: [LocationLookupResult] = []
    @State private var searchingLocation = false
    @State private var locationError = ""
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { details.fields[key] ?? "" }, set: { details.fields[key] = $0 })
    }
    var body: some View {
        Form {
            if type == .reading {
                Section("Streaming Service (optional)") {
                    Picker("Service", selection: field("Streaming Service")) {
                        Text("Not Set").tag("")
                        ForEach(Array(Set(repository.streamingServiceChoices + [details.fields["Streaming Service"] ?? ""]).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Other service", text: field("Streaming Service"))
                }
                Section("Title & Notes") {
                    TextField("Title", text: $mediaTitle, axis: .vertical)
                    TextField("Notes", text: $mediaNote, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    TextField("Tags separated by commas", text: $mediaTags, axis: .vertical).textInputAutocapitalization(.never)
                    let suggestions = ReadingMedia.suggestedTags(details.fields.merging(["Watch Links": ReadingMedia.encodeLinks(mediaLinks.map(\.link))]) { _, new in new })
                    ForEach(suggestions, id: \.self) { tag in
                        Toggle("#" + tag, isOn: Binding(get: { ReadingMedia.tagNames(mediaTags).contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }, set: { included in
                            var tags = ReadingMedia.tagNames(mediaTags)
                            if included { tags.append(tag) } else { tags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
                            mediaTags = Array(Set(tags)).sorted().joined(separator: ", ")
                        }))
                    }
                } header: { Text("Tags") } footer: { Text("Type and service tags are added on capture. Genre suggestions come from the page; you choose which to keep.") }
                if details.fields["Local Preview"] != nil || !(details.fields["Thumbnail URL"] ?? "").isEmpty {
                    Section {
                        Button("Remove Preview", role: .destructive) {
                            details.fields.removeValue(forKey: "Local Preview")
                            details.fields["Thumbnail URL"] = ""
                            details.fields["Suppress Preview"] = "true"
                        }
                    }
                }
                Section {
                    ForEach($mediaLinks) { $link in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Service or source", text: $link.provider)
                            ListURLField(title: "Link", value: $link.url)
                            TextField("Country (optional)", text: $link.region)
                            TextField("Subscription, rental, or availability note", text: $link.note, axis: .vertical)
                            Button("Remove Link", role: .destructive) { mediaLinks.removeAll { $0.id == link.id } }
                        }
                    }
                    Button("Add Watch Link", systemImage: "link.badge.plus") { mediaLinks.append(EditableMediaLink()) }
                    Menu("Choose Service Name") {
                        ForEach(repository.streamingServiceChoices, id: \.self) { service in
                            Button(service) { mediaLinks.append(EditableMediaLink(provider: service)) }
                        }
                    }
                } header: { Text(ReadingMedia.action(for: ReadingMedia.displayFormat(details.fields)) == "Watch" ? "Where to Watch · Saved Links" : "Source Links") } footer: { Text("These are saved links, not verified availability. Add a country or access note when useful. Clear Source Link as well to remove the original capture link.") }
            }
            Section {
                ForEach(type.fields.filter { !["Follow-up Date", "Essential", "Next Action", "Required", "Rating", "Shopping List ID"].contains($0) && !(type == .appointments && ["Preparation", "Questions", "Outcome"].contains($0)) && repository.listProfile(task.listID).settings["Hidden Field " + $0] != "true" }, id: \.self) { key in
                    if ["Renewal Date", "Notice Date", "Cancellation Deadline"].contains(key) {
                        Toggle(key, isOn: Binding(get: { !(details.fields[key] ?? "").isEmpty }, set: { details.fields[key] = $0 ? SpecializedTaskDetails.dateText(Date()) : "" }))
                        if !(details.fields[key] ?? "").isEmpty {
                            DatePicker(key, selection: Binding(get: { SpecializedTaskDetails.dateValue(details.fields[key] ?? "") ?? Date() }, set: { details.fields[key] = SpecializedTaskDetails.dateText($0) }), displayedComponents: .date)
                        }
                    } else if type == .reading, key == "Format" {
                        Picker("Media Type", selection: field(key)) {
                            Text("Not Set").tag("")
                            ForEach(ReadingMedia.formats, id: \.self) { Text($0).tag($0) }
                            if let existing = details.fields[key], !existing.isEmpty, !ReadingMedia.formats.contains(existing) { Text(existing).tag(existing) }
                        }
                    } else if ListFieldNumber.keys.contains(key) {
                        ListNumberField(title: key, value: field(key), integer: ListFieldNumber.integer(key), minimum: ListFieldNumber.minimum(key))
                    } else if ["Room", "Provider", "Milestone", "Section", "Category", "Destination", "Contact"].contains(key) {
                        NavigationLink {
                            ListFieldPicker(title: key, value: field(key), choices: repository.listFieldChoices(key, listID: task.listID))
                        } label: { LabeledContent(key, value: details.fields[key].flatMap { $0.isEmpty ? nil : $0 } ?? "Not Set") }
                    } else if ["Source Link", "Thumbnail URL", "Payment Link"].contains(key) {
                        ListURLField(title: key, value: field(key))
                    } else {
                        TextField(key, text: field(key), axis: .vertical).lineLimit(1...5)
                    }
                }
                ForEach(type.fields.filter { ["Essential", "Next Action", "Required"].contains($0) && repository.listProfile(task.listID).settings["Hidden Field " + $0] != "true" }, id: \.self) { key in
                    Toggle(key, isOn: Binding(get: { details.fields[key] == "Yes" }, set: { details.fields[key] = $0 ? "Yes" : "No" }))
                }
                if type == .reading, repository.listProfile(task.listID).settings["Hidden Field Rating"] != "true" { Picker("Rating", selection: field("Rating")) { Text("Unrated").tag(""); ForEach(1...5, id: \.self) { Text("\($0) stars").tag(String($0)) } } }
                if type == .errands, repository.listProfile(task.listID).settings["Hidden Field Shopping List ID"] != "true" {
                    Picker("Shopping List", selection: field("Shopping List ID")) {
                        Text("None").tag("")
                        ForEach(repository.lists.filter { repository.listProfile($0.id).type == .shopping }) { Text($0.title).tag($0.id) }
                    }
                }
                if type == .appointments {
                    if repository.showsCalendarEvents {
                        NavigationLink {
                            EventLinkPicker(repository: repository, selection: field("Event ID"))
                        } label: {
                            LabeledContent("Linked Event", value: repository.calendarEvents.first { $0.id == details.fields["Event ID"] }?.title ?? "Choose Event")
                        }
                    }
                    Toggle("Follow-up Reminder", isOn: Binding(get: { !(details.fields["Follow-up Date"] ?? "").isEmpty }, set: { details.fields["Follow-up Date"] = $0 ? SpecializedTaskDetails.dateText(Date()) : "" }))
                    if !(details.fields["Follow-up Date"] ?? "").isEmpty {
                        DatePicker("Follow-up Date", selection: Binding(get: {
                            return SpecializedTaskDetails.dateValue(details.fields["Follow-up Date"] ?? "") ?? Date()
                        }, set: { details.fields["Follow-up Date"] = SpecializedTaskDetails.dateText($0) }), displayedComponents: .date)
                    }
                }
                if !type.stages.isEmpty {
                    Picker("Stage", selection: field(type == .reading ? "Progress" : "Stage")) {
                        Text("Not Set").tag("")
                        ForEach(type.stages, id: \.self) { Text($0).tag($0) }
                    }
                }
                if type == .shopping { Toggle("Favorite purchase", isOn: $details.isFavorite) }
                if type == .household {
                    Toggle("Repeat after completion", isOn: Binding(get: { details.repeatAfterDays != nil }, set: { details.repeatAfterDays = $0 ? 7 : nil }))
                    if details.repeatAfterDays != nil {
                        Stepper("Every \(details.repeatAfterDays ?? 7) days", value: Binding(get: { details.repeatAfterDays ?? 7 }, set: { details.repeatAfterDays = $0 }), in: 1...3650)
                        Text("Creates a new reminder after completion. Disable native repeat to use this schedule.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text(type.rawValue) } footer: { Text(type.syncExplanation) }
            if type == .errands { errandLocationSection }
            if type == .appointments {
                if repository.listProfile(task.listID).settings["Hidden Field Preparation"] != "true" { Section("Before · Preparation") { TextField("One preparation step per line", text: field("Preparation"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Questions"] != "true" { Section("During · Questions") { TextField("Questions to ask", text: field("Questions"), axis: .vertical).lineLimit(2...6) } }
                if repository.listProfile(task.listID).settings["Hidden Field Outcome"] != "true" { Section("After · Outcome") { TextField("Outcome and next steps", text: field("Outcome"), axis: .vertical).lineLimit(2...6) } }
            }
        }
        .taskFlowThemedBackground()
        .navigationTitle(type == .reading ? "Edit Media" : type.detailsTitle)
        .navigationBarTitleDisplayMode(type == .reading ? .inline : .automatic)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") {
            saving = true
            Task {
                var saved = details
                for key in ListFieldNumber.keys where !(saved.fields[key] ?? "").isEmpty {
                    let raw = saved.fields[key] ?? ""
                    if let number = Double(raw.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")), number.isFinite { saved.fields[key] = ShoppingQuantity.text(number) }
                }
                if type == .errands, let location, (saved.fields["Destination"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saved.fields["Destination"] = location.displayTitle
                }
                if type == .reading { saved.fields["Watch Links"] = ReadingMedia.encodeLinks(mediaLinks.map(\.link)) }
                var succeeded = type == .reading
                    ? await repository.saveMediaItem(saved, title: mediaTitle, note: mediaNote, tags: ReadingMedia.tagNames(mediaTags), for: task)
                    : await repository.saveSpecializedDetails(saved, for: task, type: type)
                if succeeded, type == .errands, location != originalLocation {
                    // The place is saved on the reminder, where Reminders delivers its arrival alert.
                    var draft = TaskDraft(task: repository.tasks.first { $0.id == task.id } ?? task)
                    draft.location = location
                    succeeded = await repository.saveTask(draft)
                }
                if succeeded { dismiss() }
                saving = false
            }
        }.disabled(saving || searchingLocation || !validFields) } }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            details = repository.specializedDetails(task)
            if type == .reading {
                mediaTitle = task.title
                mediaNote = task.notes
                mediaTags = task.tags.joined(separator: ", ")
                mediaLinks = ReadingMedia.watchLinks(details.fields).map { EditableMediaLink(provider: $0.provider, url: $0.url, region: $0.region ?? "", note: $0.note ?? "") }
                details.fields["Format"] = ReadingMedia.displayFormat(details.fields)
            }
            location = (repository.tasks.first { $0.id == task.id } ?? task).location
            originalLocation = location
        }
    }

    private var validFields: Bool {
        if type == .reading {
            guard !mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            for link in mediaLinks {
                guard !link.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = URL(string: link.url), ReadingMedia.isWebURL(url) else { return false }
            }
            for key in ["Source Link", "Thumbnail URL"] {
                let raw = details.fields[key] ?? ""
                if !raw.isEmpty, URL(string: raw).map(ReadingMedia.isWebURL) != true { return false }
            }
        }
        for key in ListFieldNumber.keys where type.fields.contains(key) && repository.listProfile(task.listID).settings["Hidden Field " + key] != "true" {
            let raw = details.fields[key] ?? ""
            if !raw.isEmpty, ListFieldNumber.parse(raw, key: key) == nil { return false }
        }
        return true
    }

    @ViewBuilder private var errandLocationSection: some View {
        Section {
            if let current = location {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.displayTitle)
                        if current.displayAddress != current.displayTitle { Text(current.displayAddress).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: { Image(systemName: "mappin.circle.fill").foregroundStyle(.tint) }
                if current.latitude != nil, current.longitude != nil {
                    Picker("Remind Me", selection: Binding(get: { location?.proximity ?? .onArrival }, set: { location?.proximity = $0 })) {
                        ForEach(LocationProximity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Radius: \(Int(current.radius)) m", value: Binding(get: { location?.radius ?? 100 }, set: { location?.radius = $0 }), in: 50...1000, step: 50)
                }
                Button("Remove Location", role: .destructive) { location = nil }
            }
            HStack {
                TextField(location == nil ? "Search for a store or address" : "Change location", text: $locationQuery)
                    .onSubmit { searchLocation() }
                    .submitLabel(.search)
                if searchingLocation { ProgressView() }
            }
            ForEach(locationResults) { result in
                Button {
                    var chosen = result.location
                    chosen.radius = location?.radius ?? 100
                    chosen.proximity = location?.proximity ?? .onArrival
                    location = chosen
                    locationResults = []
                    locationQuery = ""
                } label: { LocationLookupRow(result: result) }
                    .tint(.primary)
            }
        } header: { Text("Location") } footer: {
            if !locationError.isEmpty { Text(locationError) }
            else { Text("Choose a place to get a Reminders alert when you arrive, and to open it in Maps.") }
        }
    }

    private func searchLocation() {
        let query = locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchingLocation, !query.isEmpty else { return }
        searchingLocation = true
        locationError = ""
        Task {
            defer { searchingLocation = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                let response = try await MKLocalSearch(request: request).start()
                locationResults = response.mapItems.prefix(5).map(LocationLookupResult.init(mapItem:))
                if locationResults.isEmpty { locationError = "No places found. Try a more specific name or address." }
            } catch { locationError = error.localizedDescription }
        }
    }
}
