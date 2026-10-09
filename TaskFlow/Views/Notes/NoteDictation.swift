import AVFoundation
import LinkPresentation
import QuickLookThumbnailing
import SafariServices
import Speech
import PhotosUI
import SwiftUI
import PencilKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class NoteDictationRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isFinishing = false
    @Published var errorMessage: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false
    private var sessionID = UUID()
    private var finishTask: Task<Void, Never>?

    func start() async {
        guard !isStarting, !isRecording, !isFinishing else { return }
        isStarting = true
        errorMessage = nil
        let id = UUID()
        sessionID = id
        defer { isStarting = false }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard speechStatus == .authorized else {
            errorMessage = "Allow Speech Recognition for TaskFlow in Settings to transcribe notes."
            return
        }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard microphoneAllowed else {
            errorMessage = "Allow Microphone access for TaskFlow in Settings to dictate notes."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable. Please try again later."
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "NoteDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            transcript = ""
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil {
                        if let error, self.isRecording { self.errorMessage = error.localizedDescription }
                        self.cancel()
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            cancel()
        }
    }

    func stop() {
        guard isRecording else { return }
        stopAudio()
        isFinishing = true
        request?.endAudio()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        sessionID = UUID()
        finishTask?.cancel()
        finishTask = nil
        stopAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isFinishing = false
    }

    private func stopAudio() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct NoteDictationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = NoteDictationRecorder()
    var autoStart = false
    var onDraftChange: ((String) -> Void)? = nil
    @State private var didAutoStart = false
    let onInsert: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(recorder.isRecording ? "Listening…" : (recorder.isFinishing ? "Finishing transcription…" : "Ready to dictate"), systemImage: recorder.isRecording ? "waveform" : "mic")
                    Button(recorder.isRecording ? "Stop Dictation" : "Start Dictation", systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill") {
                        if recorder.isRecording { recorder.stop() }
                        else { Task { await recorder.start() } }
                    }
                    .disabled(recorder.isStarting || recorder.isFinishing)
                    if let error = recorder.errorMessage { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Speak to transcribe, then review and insert the text into your note. Starting again replaces this transcript. Speech recognition may use Apple's servers.")
                }
                Section("Transcript") {
                    TextEditor(text: $recorder.transcript)
                        .frame(minHeight: 220)
                        .disabled(recorder.isRecording || recorder.isFinishing)
                }
            }
            .navigationTitle("Dictate Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onInsert(recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
                        recorder.cancel()
                        dismiss()
                    }
                    .disabled(recorder.isStarting || recorder.isRecording || recorder.isFinishing || recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onChange(of: recorder.transcript) { _, value in onDraftChange?(value) }
        .task { await startAutomaticallyIfNeeded() }
        .onDisappear { recorder.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { recorder.cancel() }
            if phase == .active { Task { await startAutomaticallyIfNeeded() } }
        }
    }

    private func startAutomaticallyIfNeeded() async {
        // Control Center and permission dialogs can briefly leave the app inactive.
        guard autoStart, !didAutoStart, scenePhase == .active else { return }
        didAutoStart = true
        await recorder.start()
    }
}
