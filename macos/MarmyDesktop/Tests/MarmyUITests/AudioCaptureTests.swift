import AVFoundation
import XCTest
@testable import MarmyUI

/// The path microphone audio takes before a recogniser sees it.
///
/// None of this opens a microphone: buffers are made by hand, which is the point
/// — a tap hands out storage it reuses the moment the callback returns.
final class BufferConverterTests: XCTestCase {

    private func format(sampleRate: Double, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    }

    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) { data[frame] = value }
        }
        return buffer
    }

    func testAConvertedBufferIsOurOwnStorage() throws {
        // The tap's buffer is on loan. What comes out must not change when the
        // audio engine reuses it a moment later.
        let source = try format(sampleRate: 48000)
        let converter = try BufferConverter(from: source, to: source)
        let tapBuffer = try buffer(source, frames: 512, value: 0.5)

        let ours = try converter.convert(tapBuffer)
        // The engine hands the same storage to the next callback.
        let data = try XCTUnwrap(tapBuffer.floatChannelData)[0]
        for frame in 0..<512 { data[frame] = -1 }

        let kept = try XCTUnwrap(ours.floatChannelData)[0]
        XCTAssertEqual(kept[0], 0.5, "our copy is untouched")
        XCTAssertEqual(kept[511], 0.5)
        XCTAssertEqual(ours.frameLength, 512)
    }

    func testItConvertsToTheFormatTheRecogniserAsksFor() throws {
        let source = try format(sampleRate: 48000)
        let target = try format(sampleRate: 16000)
        let converter = try BufferConverter(from: source, to: target)

        let converted = try converter.convert(try buffer(source, frames: 4800, value: 0.25))

        XCTAssertEqual(converted.format.sampleRate, 16000)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertLessThanOrEqual(Int(converted.frameLength), 1600 + 64)
    }

    func testAStreamOfBuffersKeepsItsOrderAndItsAudio() throws {
        let source = try format(sampleRate: 48000)
        let converter = try BufferConverter(from: source, to: try format(sampleRate: 16000))
        var outputs: [AVAudioPCMBuffer] = []
        for index in 0..<10 {
            outputs.append(try converter.convert(try buffer(source, frames: 4800, value: Float(index) / 10)))
        }

        XCTAssertEqual(outputs.count, 10)
        for output in outputs {
            XCTAssertGreaterThan(output.frameLength, 0, "no buffer is silently dropped")
        }
    }

    func testInterleavedStereoIsCopiedWhole() throws {
        // Interleaved formats keep every channel in one allocation. Copying per
        // channel pointer would read past the end of one and lose the other.
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        source.frameLength = 256
        let samples = try XCTUnwrap(source.int16ChannelData)[0]
        for index in 0..<512 { samples[index] = Int16(index % 1000) }

        let converter = try BufferConverter(from: format, to: format)
        let copy = try converter.convert(source)

        // Scribble over the original, as the audio engine would.
        for index in 0..<512 { samples[index] = -1 }

        let copied = try XCTUnwrap(copy.int16ChannelData)[0]
        XCTAssertEqual(copy.frameLength, 256)
        XCTAssertEqual(copied[0], 0)
        XCTAssertEqual(copied[1], 1, "the second channel of the first frame")
        XCTAssertEqual(copied[511], Int16(511 % 1000), "and the very last sample")
    }

    func testNonInterleavedFloatStereoIsCopiedPerChannel() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        source.frameLength = 128
        let channels = try XCTUnwrap(source.floatChannelData)
        for frame in 0..<128 {
            channels[0][frame] = 0.25
            channels[1][frame] = -0.75
        }

        let copy = try BufferConverter(from: format, to: format).convert(source)
        for frame in 0..<128 {
            channels[0][frame] = 0
            channels[1][frame] = 0
        }

        let copied = try XCTUnwrap(copy.floatChannelData)
        XCTAssertEqual(copied[0][127], 0.25)
        XCTAssertEqual(copied[1][127], -0.75)
    }

    func testAnImpossibleConversionIsReportedRatherThanIgnored() throws {
        let source = try format(sampleRate: 48000)
        // A format nothing can be converted into.
        let odd = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 0.5, channels: 1, interleaved: false)
        if let odd {
            XCTAssertThrowsError(try BufferConverter(from: source, to: odd))
        }
    }
}

/// The token that keeps one recording's audio out of another's.
final class RecordingGuardTests: XCTestCase {

    func testOnlyTheCurrentRecordingIsAccepted() {
        let guardian = RecordingGuard()
        let first = guardian.begin()
        XCTAssertTrue(guardian.isCurrent(first))

        let second = guardian.begin()
        XCTAssertFalse(guardian.isCurrent(first), "the old recording's audio is refused")
        XCTAssertTrue(guardian.isCurrent(second))

        guardian.end()
        XCTAssertFalse(guardian.isCurrent(second), "and nothing is accepted once it has stopped")
    }

    func testItIsSafeToAskFromTheAudioThread() {
        let guardian = RecordingGuard()
        let token = guardian.begin()
        let finished = expectation(description: "checked from other threads")
        finished.expectedFulfillmentCount = 4

        for _ in 0..<4 {
            DispatchQueue.global().async {
                for _ in 0..<2000 { _ = guardian.isCurrent(token) }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 10)
    }
}
