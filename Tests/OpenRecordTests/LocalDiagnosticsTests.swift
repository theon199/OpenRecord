import Darwin
import Foundation
import OpenRecord
import Testing

enum LocalDiagnosticsTests {
    static let testCount = 6

    static func run() throws {
        try requiredFieldsAndExportSettings()
        try diagnosticsTracksWinOverLegacyTiming()
        try legacyTimingAndMissingValues()
        try outputIsDeterministic()
        try errorCategoryDoesNotCarryErrorText()
        try sensitiveStringsNeverAppear()
    }

    private static func makeSnapshot(
        diagnostics: CaptureDiagnostics? = nil,
        timing: CaptureTiming? = nil,
        presence: [CaptureTrackKind: Bool] = [:],
        durations: [CaptureTrackKind: TimeInterval] = [:],
        category: LocalDiagnosticsErrorCategory = .none
    ) -> LocalDiagnosticsSnapshot {
        LocalDiagnosticsSnapshot(
            appVersion: "2.5.0",
            appBuild: "25001",
            operatingSystem: "macOS 15.6",
            architecture: "arm64",
            projectFormatVersion: 4,
            captureHealth: CaptureHealth(state: .recovered, warnings: [.missingWebcam, .lowDiskSpace]),
            captureDiagnostics: diagnostics,
            captureTiming: timing,
            trackPresence: presence,
            trackDurations: durations,
            exportSettings: VideoExportSettings(codec: .hevc, resolution: .p2160),
            lastErrorCategory: category
        )
    }

    private static func requiredFieldsAndExportSettings() throws {
        let text = makeSnapshot().text
        let required = [
            "appVersion=2.5.0",
            "appBuild=25001",
            "operatingSystem=macOS 15.6",
            "architecture=arm64",
            "projectFormatVersion=4",
            "captureHealth.state=recovered",
            "captureHealth.warnings=lowDiskSpace,missingWebcam",
            "export.codec=hevc",
            "export.resolution=4k",
            "lastErrorCategory=none"
        ]
        guard required.allSatisfy(text.contains) else {
            throw OpenRecordError.io("diagnostics omitted a required technical field")
        }
        guard CaptureTrackKind.allCases.allSatisfy({ text.contains("track.\($0.rawValue).presence=") }) else {
            throw OpenRecordError.io("diagnostics omitted one of the four capture tracks")
        }
    }

    private static func diagnosticsTracksWinOverLegacyTiming() throws {
        let diagnostics = CaptureDiagnostics(
            referenceDuration: 60,
            driftTolerance: 0.1,
            tracks: [
                CaptureTrackDiagnostic(track: .displayVideo, status: .complete, duration: 60),
                CaptureTrackDiagnostic(
                    track: .webcam,
                    status: .truncated,
                    initialOffset: 0.125,
                    duration: 58.5,
                    endDrift: -1.375,
                    correction: CaptureTrackCorrection(sourceDuration: 58.5, timelineDuration: 59.875)
                )
            ]
        )
        let text = makeSnapshot(
            diagnostics: diagnostics,
            timing: CaptureTiming(webcamOffset: 9.0),
            presence: [.webcam: false],
            durations: [.webcam: 2]
        ).text
        guard text.contains("track.webcam.presence=true"),
              text.contains("track.webcam.status=truncated"),
              text.contains("track.webcam.duration=58.5"),
              text.contains("track.webcam.initialOffset=0.125"),
              text.contains("track.webcam.endDrift=-1.375"),
              text.contains("sourceDuration=58.5"),
              !text.contains("track.webcam.initialOffset=9")
        else {
            throw OpenRecordError.io("diagnostic track data did not take precedence over legacy timing")
        }
    }

    private static func legacyTimingAndMissingValues() throws {
        let text = makeSnapshot(
            timing: CaptureTiming(systemAudioOffset: -0.25, microphoneOffset: 0.5, webcamOffset: 0.75),
            presence: [.displayVideo: true, .systemAudio: false],
            durations: [.displayVideo: 12.5]
        ).text
        guard text.contains("track.displayVideo.status=complete"),
              text.contains("track.displayVideo.duration=12.5"),
              text.contains("track.displayVideo.initialOffset=0"),
              text.contains("track.systemAudio.status=missing"),
              text.contains("track.systemAudio.initialOffset=-0.25"),
              text.contains("track.microphone.initialOffset=0.5"),
              text.contains("track.webcam.initialOffset=0.75"),
              text.contains("track.microphone.duration=unknown"),
              text.contains("track.webcam.correction=none")
        else {
            throw OpenRecordError.io("legacy capture timing or missing values were formatted incorrectly")
        }
    }

    private static func outputIsDeterministic() throws {
        let diagnostics = CaptureDiagnostics(
            referenceDuration: 10,
            driftTolerance: 0.1,
            tracks: [
                CaptureTrackDiagnostic(track: .webcam, status: .complete, initialOffset: 0.00123456, duration: 10)
            ]
        )
        let first = makeSnapshot(
            diagnostics: diagnostics,
            presence: [.webcam: true, .displayVideo: true],
            durations: [.webcam: 99, .displayVideo: 10]
        )
        let second = makeSnapshot(
            diagnostics: diagnostics,
            presence: [.displayVideo: true, .webcam: true],
            durations: [.displayVideo: 10, .webcam: 99]
        )
        guard first == second, first.text == second.text,
              first.text.contains("track.webcam.initialOffset=0.001235")
        else {
            throw OpenRecordError.io("diagnostics output was not deterministic or locale-stable")
        }
    }

    private static func errorCategoryDoesNotCarryErrorText() throws {
        let text = makeSnapshot(category: .projectSave).text
        guard text.contains("lastErrorCategory=projectSave"),
              !text.contains("errorMessage"),
              !text.contains("localizedDescription")
        else {
            throw OpenRecordError.io("diagnostics emitted arbitrary error details")
        }
    }

    private static func sensitiveStringsNeverAppear() throws {
        let text = LocalDiagnosticsSnapshot(
            appVersion: "2.5.0",
            appBuild: "25001",
            operatingSystem: "macOS",
            architecture: "arm64",
            projectFormatVersion: 4,
            exportSettings: .default,
            lastErrorCategory: .capture
        ).text
        let sensitive = ["secret-title", "secret-path", "/Users/", "device-serial", "caption text", "typed key"]
        guard !sensitive.contains(where: { text.contains($0) }),
              text.split(separator: "\n").allSatisfy({ !$0.contains("\r") })
        else {
            throw OpenRecordError.io("diagnostics contained a sensitive string or malformed line")
        }
    }
}

@Test
func localDiagnosticsPhase6Contracts() throws {
    try LocalDiagnosticsTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordLocalDiagnosticsTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunLocalDiagnosticsTests()
}

@_cdecl("OpenRecordRunLocalDiagnosticsTests")
func OpenRecordRunLocalDiagnosticsTests() {
    do {
        try LocalDiagnosticsTests.run()
        fputs(
            "OpenRecordTests: LocalDiagnosticsTests files=1 tests=\(LocalDiagnosticsTests.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: LocalDiagnosticsTests files=1 tests=\(LocalDiagnosticsTests.testCount) failures=1 error=\(error)\n", stderr)
        abort()
    }
}
#endif
