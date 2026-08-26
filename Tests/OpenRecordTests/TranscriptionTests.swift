import Foundation
import Testing
import OpenRecord

@Test("transcription normalizes offsets and keeps edited display text")
func transcriptionNormalizationAndDisplay() throws {
    let fragments = [RecognizedTranscriptFragment(
        start: 1.25,
        duration: 0.5,
        text: "  Open   settings. ",
        confidence: 1.2,
        source: .microphone
    )]
    let segments = TranscriptionNormalizer.normalize(fragments, trackOffset: 2)
    guard let segment = segments.first,
          segment.start == 3.25,
          segment.end == 3.75,
          segment.recognizedText == "Open settings.",
          segment.displayText == "Open settings.",
          segment.confidence == 1
    else { throw OpenRecordError.io("transcription normalization contract failed") }

    var edited = segment
    edited.editedText = "Open the settings panel."
    guard edited.displayText == "Open the settings panel." else {
        throw OpenRecordError.io("manual transcript text did not win display rendering")
    }
}

@Test("caption regeneration preserves existing captions unless overwrite is explicit")
func captionRegenerationPreservesEdits() throws {
    let segment = TranscriptSegment(
        start: 0,
        end: 2,
        recognizedText: "This is the recognized phrase.",
        source: .microphone
    )
    let existing = [CaptionCue(start: 0, end: 2, text: "User wording")]
    let preserved = CaptionGenerator.regenerate(from: [segment], existing: existing)
    guard preserved == existing else { throw OpenRecordError.io("caption edit was overwritten") }
    let replaced = CaptionGenerator.regenerate(from: [segment], existing: existing, overwrite: true)
    guard replaced.first?.text == segment.displayText else {
        throw OpenRecordError.io("explicit caption overwrite did not regenerate")
    }
}
