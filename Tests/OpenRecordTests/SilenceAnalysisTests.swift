import Foundation
import Testing
import OpenRecord

@Test("silence presets detect deterministic pause ranges and breathing room")
func silencePresetsAndBreathingRoom() throws {
    let samples = stride(from: 0.0, through: 3.0, by: 0.5).map { time in
        AudioLevelSample(timestamp: time, decibels: time >= 1 && time < 2.5 ? -60 : -10)
    }
    let suggestions = SilenceAnalyzer.detect(
        samples: samples,
        options: SilenceAnalysisOptions(preset: .natural, retainedBreathingRoom: 0.2)
    )
    guard let pause = suggestions.first,
          pause.start == 1,
          pause.end == 2.5,
          pause.cutStart == 1.2,
          pause.cutEnd == 2.3
    else { throw OpenRecordError.io("natural silence range or breathing room failed") }
}

@Test("transcript gaps can supplement audio silence and map to authoritative exclusions")
func transcriptGapsAndAcceptedDecisions() throws {
    let transcript = [
        TranscriptSegment(start: 0, end: 1, recognizedText: "first", source: .microphone),
        TranscriptSegment(start: 2.5, end: 3, recognizedText: "second", source: .microphone),
    ]
    let suggestions = SilenceAnalyzer.detect(
        samples: [],
        options: SilenceAnalysisOptions(preset: .fast, retainedBreathingRoom: 0),
        transcript: transcript
    )
    guard suggestions.count == 1, suggestions[0].start == 1, suggestions[0].end == 2.5 else {
        throw OpenRecordError.io("transcript gap suggestion failed")
    }
    let mapper = ProjectTimeMapper(sourceDuration: 4, trimIn: 0.5, trimOut: 3.5)
    let decisions = PauseSuggestionApplier.acceptedEditDecisions(suggestions, mapper: mapper)
    guard decisions.count == 1, decisions[0].start == 1, decisions[0].end == 2.5 else {
        throw OpenRecordError.io("accepted pause did not normalize through mapper bounds")
    }
}

@Test("audio levels map capture offsets and drift correction onto the project clock")
func audioLevelTimelineMappingUsesCaptureRate() throws {
    let mapped = LocalAudioLevelAnalyzer.mapToTimeline(
        [
            AudioLevelSample(timestamp: 0.1, decibels: -10),
            AudioLevelSample(timestamp: 0.5, decibels: -20),
            AudioLevelSample(timestamp: 2.5, decibels: -30),
        ],
        offset: -0.25,
        sourceRate: 2
    )
    guard mapped.map(\.timestamp) == [0, 1] else {
        throw OpenRecordError.io("audio levels did not map from source time to the project clock")
    }
}
