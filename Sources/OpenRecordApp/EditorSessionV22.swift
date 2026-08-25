import AppKit
import Foundation
import OpenRecord
import UniformTypeIdentifiers

enum EditorExportKind: CaseIterable, Identifiable {
    case video
    case gif
    case audio
    case snapshot

    var id: Self { self }

    var contentType: UTType {
        switch self {
        case .video: .mpeg4Movie
        case .gif: .gif
        case .audio: .mpeg4Audio
        case .snapshot: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .video: "mp4"
        case .gif: "gif"
        case .audio: "m4a"
        case .snapshot: "png"
        }
    }

    var panelTitle: String {
        switch self {
        case .video: "Export Video"
        case .gif: "Export GIF"
        case .audio: "Export Audio"
        case .snapshot: "Export Snapshot"
        }
    }

    var message: String {
        switch self {
        case .video: "Renders the current trim, overlays, and canvas into an MP4."
        case .gif: "Renders the current trim and overlays into an animated GIF."
        case .audio: "Exports the mixed project audio for the current trim."
        case .snapshot: "Exports the current playhead frame as a PNG image."
        }
    }
}

@MainActor
extension EditorSession {
    func selectZoom(_ id: UUID?) {
        selectedZoomID = id
        if id != nil {
            selectedSpeedID = nil
            selectedCaptionID = nil
            selectedAnnotationID = nil
            isWebcamSelected = false
        }
    }

    func selectSpeed(_ id: UUID?) {
        selectedSpeedID = id
        if id != nil {
            selectedZoomID = nil
            selectedCaptionID = nil
            selectedAnnotationID = nil
            isWebcamSelected = false
        }
    }

    func selectCaption(_ id: UUID?) {
        selectedCaptionID = id
        if id != nil {
            selectedZoomID = nil
            selectedSpeedID = nil
            selectedAnnotationID = nil
            isWebcamSelected = false
        }
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
        if id != nil {
            selectedZoomID = nil
            selectedSpeedID = nil
            selectedCaptionID = nil
            isWebcamSelected = false
        }
    }

    func selectWebcam() {
        guard hasWebcamVideo, document.webcamOverlay.enabled else { return }
        isWebcamSelected = true
        selectedZoomID = nil
        selectedSpeedID = nil
        selectedCaptionID = nil
        selectedAnnotationID = nil
    }

    func addCaptionAtPlayhead() {
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 3, timelineDuration)
        guard end - start >= 0.05 else { return }
        let before = document
        let cue = CaptionCue(start: start, end: end, text: "Caption")
        document.captions.append(cue)
        document.captions.sort { $0.start < $1.start }
        selectCaption(cue.id)
        documentDidChange(from: before, actionName: "Add Caption")
    }

    func updateSelectedCaption(_ body: (inout CaptionCue) -> Void) {
        guard let selectedCaptionID,
              let index = document.captions.firstIndex(where: { $0.id == selectedCaptionID })
        else { return }
        let before = document
        var cue = document.captions[index]
        body(&cue)
        cue = normalizedCaption(cue)
        document.captions[index] = cue
        document.captions.sort { $0.start < $1.start }
        documentDidChange(from: before, actionName: "Edit Caption")
    }

    func replaceCaption(_ cue: CaptionCue) {
        guard let index = document.captions.firstIndex(where: { $0.id == cue.id }) else { return }
        let before = document
        document.captions[index] = normalizedCaption(cue)
        document.captions.sort { $0.start < $1.start }
        documentDidChange(from: before, actionName: "Adjust Caption")
    }

    func deleteSelectedCaption() {
        guard let selectedCaptionID else { return }
        let before = document
        document.captions.removeAll { $0.id == selectedCaptionID }
        self.selectedCaptionID = nil
        documentDidChange(from: before, actionName: "Delete Caption")
    }

    func importCaptionsPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Captions"
        panel.message = "Choose an SRT or WebVTT caption file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try CaptionParser.parse(url: url)
            guard !imported.isEmpty else { return }
            let before = document
            document.captions.append(contentsOf: imported.map(normalizedCaption))
            document.captions.sort { $0.start < $1.start }
            selectedCaptionID = imported.first?.id
            selectedZoomID = nil
            selectedSpeedID = nil
            selectedAnnotationID = nil
            isWebcamSelected = false
            documentDidChange(from: before, actionName: "Import Captions")
        } catch {
            lastError = "Could not import captions: \(error.localizedDescription)"
        }
    }

    func addAnnotationAtPlayhead(kind: AnnotationKind = .text) {
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 3, timelineDuration)
        guard end - start >= 0.05 else { return }
        let before = document
        let annotation: Annotation
        switch kind {
        case .text: annotation = .textCallout(start: start, end: end)
        case .arrow: annotation = .arrow(start: start, end: end)
        case .spotlight: annotation = .spotlight(start: start, end: end)
        }
        document.annotations.append(annotation)
        document.annotations.sort { $0.start < $1.start }
        selectAnnotation(annotation.id)
        documentDidChange(from: before, actionName: "Add Annotation")
    }

    func updateSelectedAnnotation(_ body: (inout Annotation) -> Void) {
        guard let selectedAnnotationID,
              let index = document.annotations.firstIndex(where: { $0.id == selectedAnnotationID })
        else { return }
        let before = document
        var annotation = document.annotations[index]
        body(&annotation)
        document.annotations[index] = annotation.normalized
        document.annotations.sort { $0.start < $1.start }
        documentDidChange(from: before, actionName: "Edit Annotation")
    }

    func replaceAnnotation(_ annotation: Annotation) {
        guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        let before = document
        document.annotations[index] = annotation.normalized
        document.annotations.sort { $0.start < $1.start }
        documentDidChange(from: before, actionName: "Adjust Annotation")
    }

    func deleteSelectedAnnotation() {
        guard let selectedAnnotationID else { return }
        let before = document
        document.annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        documentDidChange(from: before, actionName: "Delete Annotation")
    }

    func updateVideoExportSettings(_ body: (inout VideoExportSettings) -> Void) {
        let before = document
        body(&document.videoExportSettings)
        clampWebcamOverlayToCanvas()
        documentDidChange(from: before, actionName: "Change Export Settings")
    }

    private func normalizedCaption(_ cue: CaptionCue) -> CaptionCue {
        var value = cue
        value.start = min(max(value.start, 0), timelineDuration)
        value.end = min(max(value.end, value.start + 0.05), timelineDuration)
        if value.end <= value.start { value.start = max(0, value.end - 0.05) }
        return value.normalized
    }
}
