import XCTest
@testable import LectureCore

final class TeacherVoiceTests: XCTestCase {
    func testLegacyTranscriptDoesNotInventTeacherAttribution() throws {
        let data = Data(#"{"id":"1","start":0,"end":4,"text":"Ejemplo"}"#.utf8)
        let segment = try JSONDecoder().decode(MediaTranscriptSegment.self, from: data)
        XCTAssertNil(segment.teacherSimilarity)
        XCTAssertFalse(segment.likelyTeacher)
        var reviewed = segment
        reviewed.teacherSimilarity = 0.64
        XCTAssertFalse(reviewed.likelyTeacher)
        reviewed.teacherSimilarity = 0.8
        XCTAssertTrue(reviewed.likelyTeacher)
        XCTAssertEqual(try JSONDecoder().decode(MediaTranscriptSegment.self, from: JSONEncoder().encode(reviewed)), reviewed)
    }
    func testTeacherReferenceIsScopedToRecordingAndSurvivesRecovery() throws {
        var job = MediaJob(notebookID: "fixture", subject: "Example", note: "Example.md", sourceName: "Example.wav")
        XCTAssertNil(job.teacherReference)
        job.teacherReference = .init(path: "media/fixture/reference.wav", start: 300, duration: 8)
        let restored = try JSONDecoder().decode(MediaJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.teacherReference, job.teacherReference)
    }
    func testInferenceLeavesGPUAndCPUHeadroom() {
        let args = WhisperConfiguration().arguments(model: URL(fileURLWithPath: "/model"), audio: URL(fileURLWithPath: "/audio"), output: URL(fileURLWithPath: "/result"))
        XCTAssertTrue(args.contains("-ng"))
        XCTAssertEqual(args[args.firstIndex(of: "-t")! + 1], "2")
    }
}

final class SpeechAudioLevelTests: XCTestCase {
    func testGainIsBoundedAndSilenceIsNotAmplified() {
        XCTAssertEqual(SpeechAudioLevel.gain(rms: 0, peak: 0), 1)
        XCTAssertEqual(SpeechAudioLevel.gain(rms: .nan, peak: 0.1), 1)
        XCTAssertEqual(SpeechAudioLevel.gain(rms: 0.00001, peak: 0.00002), 1)
        XCTAssertEqual(SpeechAudioLevel.gain(rms: 0.001, peak: 0.002), 7.943282347, accuracy: 0.0001)
        XCTAssertEqual(SpeechAudioLevel.gain(rms: 0.02, peak: 0.95), 1)
        XCTAssertLessThanOrEqual(SpeechAudioLevel.gain(rms: 0.02, peak: 0.5) * 0.5, 0.892)
    }
    func testNormalizationPreservesTimingAndAvoidsClipping() {
        var samples: [Int16] = [0, 200, -200, 300, -300]
        let original = samples
        samples.withUnsafeMutableBufferPointer { SpeechAudioLevel.normalize($0) }
        XCTAssertEqual(samples.count, original.count)
        XCTAssertEqual(samples[0], 0)
        XCTAssertGreaterThan(samples[1], original[1])
        XCTAssertEqual(samples[1], -samples[2])
        var loud: [Int16] = [Int16.min, Int16.max, 0]
        let before = loud
        loud.withUnsafeMutableBufferPointer { SpeechAudioLevel.normalize($0) }
        XCTAssertEqual(loud, before)
    }
    func testNormalizationDoesNotChangeLegacyCheckpointPolicy() throws {
        let old = try JSONDecoder().decode(WhisperConfiguration.self, from: Data(#"{"model":"small","importChunkSeconds":30,"conditionOnPreviousText":false}"#.utf8))
        XCTAssertNil(old.normalizeAudio)
        XCTAssertEqual(WhisperConfiguration().normalizeAudio, true)
        var job = MediaJob(notebookID: "fixture", subject: "Example", note: "Example.md", sourceName: "Example.wav")
        job.completedChunks = 1
        XCTAssertEqual(try WhisperConfiguration.resolved(for: job).normalizeAudio, false)
    }
    func testShortRepeatedHallucinationsNeedReview() {
        let segments = (0..<5).map { MediaTranscriptSegment(id: "\($0)", start: Double($0), end: Double($0+1), text: "Gracias.") }
        XCTAssertNotNil(ASRQuality.repetitionWarning(segments))
    }
}
