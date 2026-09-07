import AVFoundation
import Foundation

/// Turns microphone buffers into buffers a recogniser can keep.
///
/// A tap hands out a buffer the audio engine owns and will reuse the moment the
/// callback returns, so nothing may hold on to it. Every buffer that leaves here
/// is this object's own storage, converted on the audio thread where it arrives.
public final class BufferConverter: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case cannotConvert(from: String, to: String)
        case allocationFailed
        case conversionFailed(String)

        public var description: String {
            switch self {
            case .cannotConvert(let from, let to):
                return "The microphone's audio (\(from)) could not be converted to \(to)."
            case .allocationFailed:
                return "There was no room to convert the microphone's audio."
            case .conversionFailed(let detail):
                return "The microphone's audio could not be converted: \(detail)"
            }
        }
    }

    public let sourceFormat: AVAudioFormat
    public let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    /// Mono, at the input's own sample rate: what several channels become before
    /// anything else is done to them. Nil when the input is already mono, or
    /// when the recogniser wants more than one channel.
    private let downmixFormat: AVAudioFormat?

    public init(from source: AVAudioFormat, to target: AVAudioFormat?) throws {
        self.sourceFormat = source
        self.targetFormat = target ?? source

        // Several channels into one is done here, deliberately, and never left
        // to the converter. Asked to go from more than one channel to one with
        // no layout to reason about, Core Audio takes the first channel and
        // reports no error, so speech on any other channel is recorded as
        // silence and nobody is told. Averaging every channel cannot lose the
        // one the voice is on, whatever the device's wiring turns out to be.
        let needsDownmix = source.channelCount > 1
            && (target?.channelCount ?? source.channelCount) == 1
        let downmix = needsDownmix
            ? AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1)
            : nil
        self.downmixFormat = downmix

        // What the converter still has to do after that: the sample rate, and
        // the sample type.
        let converterSource = downmix ?? source
        if let target, target != converterSource {
            guard let converter = AVAudioConverter(from: converterSource, to: target) else {
                throw Failure.cannotConvert(from: "\(converterSource)", to: "\(target)")
            }
            converter.primeMethod = .none
            self.converter = converter
        } else {
            self.converter = nil
        }
    }

    /// A buffer of our own, in the recogniser's format.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let buffer = downmixFormat == nil ? buffer : try downmixed(buffer)
        guard let converter else { return try Self.copy(buffer) }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw Failure.allocationFailed
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error { throw Failure.conversionFailed(error.localizedDescription) }
        guard status != .error else { throw Failure.conversionFailed("the converter refused the audio") }
        return output
    }

    /// Every channel averaged into one, at the input's own sample rate.
    ///
    /// Reads the buffer as it actually is: `stride` is 1 for the non-interleaved
    /// buffers an audio tap hands out, and the channel count for an interleaved
    /// one, so the same walk is right for both. No allocation per sample, and
    /// nothing is kept — the buffer is the audio thread's and is reused the
    /// moment this returns.
    func downmixed(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let downmixFormat else { return buffer }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: downmixFormat, frameCapacity: max(buffer.frameLength, 1))
        else { throw Failure.allocationFailed }
        output.frameLength = buffer.frameLength
        guard let destination = output.floatChannelData?[0] else { throw Failure.allocationFailed }

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        guard frames > 0, channels > 0 else { return output }

        if let source = buffer.floatChannelData {
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame * stride] }
                destination[frame] = sum * scale
            }
        } else if let source = buffer.int16ChannelData {
            let scale = 1 / (Float(channels) * 32768)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(source[channel][frame * stride]) }
                destination[frame] = sum * scale
            }
        } else if let source = buffer.int32ChannelData {
            let scale = 1 / (Float(channels) * 2_147_483_648)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(source[channel][frame * stride]) }
                destination[frame] = sum * scale
            }
        } else {
            throw Failure.cannotConvert(from: "\(buffer.format)", to: "\(downmixFormat)")
        }
        return output
    }

    /// A deep copy, for when no conversion is needed.
    ///
    /// The tap's buffer is on loan and is reused as soon as the callback
    /// returns. This copies the buffer list as it actually is: interleaved
    /// formats keep every channel in one allocation, so copying per channel
    /// pointer would read past the end of one and lose half of the other.
    static func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            throw Failure.allocationFailed
        }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { throw Failure.allocationFailed }

        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else {
                throw Failure.allocationFailed
            }
            let bytes = Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            memcpy(to, from, bytes)
            destination[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}

/// Says whether audio still belongs to the recording that asked for it.
///
/// The tap runs on an audio thread while starting and stopping happen on the
/// main actor, so the check has to be safe from both.
public final class RecordingGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    public init() {}

    public func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return current
    }

    public func end() {
        lock.lock(); defer { lock.unlock() }
        current += 1
    }

    public func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == token
    }
}

/// The microphone, as the engines use it. Tests substitute their own.
@MainActor
public protocol MicrophoneCapturing: AnyObject {
    var isRunning: Bool { get }
    func start(
        targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (BufferConverter.Failure) -> Void
    ) throws
    func stop()
}

/// The microphone, opened once per dictation.
///
/// Buffers are converted and handed on from the audio thread itself: nothing is
/// queued onto another actor, so nothing arrives out of order and nothing is
/// still in flight when the recording ends.
@MainActor
public final class AudioCapture: MicrophoneCapturing {
    public private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let guardian = RecordingGuard()
    private var isTapInstalled = false

    public init() {}

    public var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Starts the microphone.
    ///
    /// `targetFormat` must already be known: the converter is built before a
    /// single buffer arrives, so no audio is ever delivered in the wrong format
    /// or dropped while a format is worked out.
    public func start(
        targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (BufferConverter.Failure) -> Void
    ) throws {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureError.noInput
        }
        let converter = try BufferConverter(from: format, to: targetFormat)
        let token = guardian.begin()
        let guardian = self.guardian

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Audio thread. The buffer is on loan and must not outlive this call.
            guard guardian.isCurrent(token) else { return }
            do {
                onBuffer(try converter.convert(buffer))
            } catch let failure as BufferConverter.Failure {
                onFailure(failure)
            } catch {
                onFailure(.conversionFailed(error.localizedDescription))
            }
        }
        isTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        isRunning = true
    }

    /// Stops the microphone and guarantees no further buffers.
    ///
    /// The engine is stopped and the tap removed before anything downstream is
    /// closed, so the last thing said is already delivered by the time this
    /// returns.
    public func stop() {
        guardian.end()
        if engine.isRunning { engine.stop() }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        isRunning = false
    }
}

public enum AudioCaptureError: Error, CustomStringConvertible {
    case noInput
    case engine(String)

    public var description: String {
        switch self {
        case .noInput:
            return "No microphone input was found. Check the input device in System Settings."
        case .engine(let detail):
            return "The microphone could not start: \(detail)"
        }
    }
}
