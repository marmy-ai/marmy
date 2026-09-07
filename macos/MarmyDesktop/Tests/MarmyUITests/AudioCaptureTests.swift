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

/// Several microphone channels becoming the one the recogniser wants.
///
/// The case that started this: a four-channel input device, and speech on a
/// channel other than the first. Left to Core Audio, that conversion returns the
/// first channel and reports no error — a clean recording of silence, with
/// nothing to say why. Nothing here opens a microphone; every buffer is made by
/// hand, and each channel is tried in turn rather than assuming which one
/// carries the voice.
final class ChannelDownmixTests: XCTestCase {

    private let speechTarget = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// A format with more channels than a plain initialiser will make: above two
    /// it needs a layout, and "discrete, in order" is the honest one for an
    /// interface whose channels are just sockets.
    private func multichannel(
        sampleRate: Double, channels: UInt32, interleaved: Bool
    ) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: interleaved ? 4 * channels : 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? 4 * channels : 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
        return try XCTUnwrap(AVAudioFormat(streamDescription: &description, channelLayout: layout))
    }

    /// A buffer with a steady tone on one channel and silence on the others.
    private func buffer(
        _ format: AVAudioFormat, frames: AVAudioFrameCount, speakingOn channel: Int
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        let stride = buffer.stride
        for index in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                let value = index == channel
                    ? sinf(2 * .pi * 440 * Float(frame) / Float(format.sampleRate)) * 0.5
                    : 0
                data[index][frame * stride] = value
            }
        }
        return buffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer) throws -> Float {
        let frames = Int(buffer.frameLength)
        XCTAssertGreaterThan(frames, 0, "the conversion produced no audio at all")
        var total: Float = 0
        if let data = buffer.int16ChannelData {
            for frame in 0..<frames {
                let value = Float(data[0][frame * buffer.stride]) / 32768
                total += value * value
            }
        } else {
            let data = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<frames {
                let value = data[0][frame * buffer.stride]
                total += value * value
            }
        }
        return (total / Float(frames)).squareRoot()
    }

    // MARK: - Every channel is heard

    func testStereoSpeechOnEitherChannelSurvives() throws {
        let source = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48000, channels: 2))
        let converter = try BufferConverter(from: source, to: speechTarget)

        for channel in 0..<2 {
            let heard = try rms(converter.convert(buffer(source, frames: 4800, speakingOn: channel)))
            XCTAssertGreaterThan(heard, 0.05, "channel \(channel) was dropped")
        }
    }

    func testFourChannelSpeechOnAnyChannelSurvives() throws {
        // Four inputs, and no way to know which one is wired to a microphone.
        for interleaved in [false, true] {
            let source = try multichannel(sampleRate: 48000, channels: 4, interleaved: interleaved)
            let converter = try BufferConverter(from: source, to: speechTarget)
            for channel in 0..<4 {
                let heard = try rms(
                    converter.convert(buffer(source, frames: 4800, speakingOn: channel)))
                XCTAssertGreaterThan(
                    heard, 0.02,
                    "channel \(channel) was dropped (interleaved: \(interleaved))")
            }
        }
    }

    func testEveryChannelContributesRatherThanOneWinning() throws {
        let source = try multichannel(sampleRate: 48000, channels: 4, interleaved: false)
        let converter = try BufferConverter(from: source, to: speechTarget)

        let one = try rms(converter.convert(buffer(source, frames: 4800, speakingOn: 0)))
        let another = try rms(converter.convert(buffer(source, frames: 4800, speakingOn: 3)))
        XCTAssertEqual(one, another, accuracy: 0.01,
                       "an average treats the channels alike; picking one does not")
    }

    // MARK: - What the recogniser is handed

    func testTheResultIsTheRecognisersFormatAndSampleRate() throws {
        let source = try multichannel(sampleRate: 48000, channels: 4, interleaved: false)
        let converter = try BufferConverter(from: source, to: speechTarget)

        let converted = try converter.convert(buffer(source, frames: 4800, speakingOn: 1))

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.format.sampleRate, 16000)
        XCTAssertEqual(converted.format.commonFormat, .pcmFormatInt16)
        // 48k to 16k: about a third of the frames. Not exactly — the resampler
        // holds some input back — but clearly resampled rather than passed on.
        XCTAssertGreaterThan(converted.frameLength, 1200)
        XCTAssertLessThanOrEqual(converted.frameLength, 1600)
        let data = try XCTUnwrap(converted.int16ChannelData)
        for frame in 0..<Int(converted.frameLength) {
            XCTAssertNotEqual(data[0][frame], Int16.min, "no sample is a broken value")
        }
    }

    func testAConvertedBufferIsStillOurOwnStorage() throws {
        let source = try multichannel(sampleRate: 48000, channels: 4, interleaved: false)
        let converter = try BufferConverter(from: source, to: speechTarget)
        let tapBuffer = try buffer(source, frames: 4800, speakingOn: 2)

        let ours = try converter.convert(tapBuffer)
        let before = try rms(ours)
        // The engine reuses the tap's storage the moment the callback returns.
        let data = try XCTUnwrap(tapBuffer.floatChannelData)
        for channel in 0..<4 {
            for frame in 0..<4800 { data[channel][frame * tapBuffer.stride] = 0 }
        }

        XCTAssertEqual(try rms(ours), before, accuracy: 0.0001)
    }

    // MARK: - What must not change

    func testAMonoInputIsLeftExactlyAsItWas() throws {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = try BufferConverter(from: source, to: source)
        let original = try buffer(source, frames: 512, speakingOn: 0)

        let converted = try converter.convert(original)

        XCTAssertEqual(converted.format, source, "no downmix stage for audio that is already mono")
        XCTAssertEqual(converted.frameLength, 512)
        let heard = try rms(converted)
        XCTAssertEqual(heard, try rms(original), accuracy: 0.0001)
    }

    func testAStereoTargetIsNotDownmixed() throws {
        // Only a mono recogniser asks for this; anything else is left alone.
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        let converter = try BufferConverter(from: source, to: target)

        let converted = try converter.convert(buffer(source, frames: 4800, speakingOn: 1))
        XCTAssertEqual(converted.format.channelCount, 2)
    }
}
