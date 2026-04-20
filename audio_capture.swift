#!/usr/bin/env swift
//
// audio_capture.swift
// Captures system audio (ScreenCaptureKit) + microphone (AVAudioEngine),
// mixes them, and outputs raw PCM (16-bit signed LE, mono, 16000 Hz) to stdout.
//
// Requirements:
//   - macOS 13.0+ (Ventura)
//   - Screen Recording permission (System Settings > Privacy & Security)
//   - Microphone permission
//
// Build:
//   swiftc -O -o audio_capture audio_capture.swift \
//       -framework ScreenCaptureKit -framework AVFoundation \
//       -framework CoreMedia -framework CoreAudio
//
// Usage:
//   ./audio_capture | some_consumer
//   ./audio_capture --system-only
//   ./audio_capture --mic-only
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

// MARK: - Configuration

let kTargetSampleRate: Double = 16000
let kTargetChannels: AVAudioChannelCount = 1
let kBufferFrames: AVAudioFrameCount = 1024

// MARK: - Parse Arguments

enum CaptureMode {
    case both
    case systemOnly
    case micOnly
}

func parseArgs() -> CaptureMode {
    let args = CommandLine.arguments
    if args.contains("--system-only") { return .systemOnly }
    if args.contains("--mic-only") { return .micOnly }
    if args.contains("--help") || args.contains("-h") {
        FileHandle.standardError.write(Data("""
        Usage: audio_capture [OPTIONS]

        Captures system audio and/or microphone, outputs raw PCM to stdout.
        Format: 16-bit signed LE, mono, 16000 Hz

        Options:
          --system-only   Capture system audio only (no microphone)
          --mic-only      Capture microphone only (no system audio)
          --help, -h      Show this help message

        Requires Screen Recording permission for system audio capture.
        Requires Microphone permission for mic capture.

        """.utf8))
        exit(0)
    }
    return .both
}

let captureMode = parseArgs()

// MARK: - Logging to stderr (stdout is for PCM data)

func log(_ message: String) {
    let msg = "[audio_capture] \(message)\n"
    FileHandle.standardError.write(Data(msg.utf8))
}

// MARK: - Thread-safe Ring Buffer for Audio Mixing

/// Simple lock-free-ish ring buffer for float samples.
/// Used to accumulate samples from both sources before mixing.
class AudioRingBuffer {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            buffer[writeIndex % capacity] = sample
            writeIndex += 1
        }
    }

    /// Read up to `count` samples. Returns zeros if not enough data.
    func read(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var result = [Float](repeating: 0, count: count)
        let available = writeIndex - readIndex
        let toRead = min(count, available)
        for i in 0..<toRead {
            result[i] = buffer[(readIndex + i) % capacity]
        }
        readIndex += toRead
        return result
    }

    var availableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeIndex - readIndex
    }
}

// MARK: - PCM Output

/// Convert Float32 samples [-1.0, 1.0] to Int16 LE and write to stdout.
func outputPCMToStdout(_ samples: [Float]) {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        let int16Val = Int16(clamped * Float(Int16.max))
        var le = int16Val.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }
    FileHandle.standardOutput.write(data)
}

// MARK: - AVAudioConverter Helper

/// Converts an AVAudioPCMBuffer from its source format to mono Float32 at the target sample rate.
class AudioFormatConverter {
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: kTargetSampleRate,
            channels: kTargetChannels,
            interleaved: false
        )!
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = inputBuffer.format

        // If formats match, just extract samples
        if inputFormat.sampleRate == kTargetSampleRate
            && inputFormat.channelCount == kTargetChannels
            && inputFormat.commonFormat == .pcmFormatFloat32 {
            return extractFloats(from: inputBuffer)
        }

        // Create or recreate converter if input format changed
        if converter == nil || converter!.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            if converter == nil {
                log("Failed to create AVAudioConverter from \(inputFormat) to \(outputFormat)")
                return nil
            }
            converter!.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter!.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        }

        let ratio = kTargetSampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: outputFrameCount + 16) else {
            return nil
        }

        var error: NSError?
        var hasData = true
        let status = converter!.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if status == .error {
            log("AVAudioConverter error: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        return extractFloats(from: outputBuffer)
    }

    private func extractFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return nil }

        // Mono: just the first channel
        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: frameLength))
    }
}

// MARK: - CMSampleBuffer -> AVAudioPCMBuffer

extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else {
            return nil
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame
        ) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        do {
            try withAudioBufferList { abl, _ in
                // The buffer list from ScreenCaptureKit contains the audio data.
                // Copy it into our PCM buffer.
                let ablPtr = abl.unsafePointer
                guard let srcBuf = ablPtr.pointee.mBuffers.mData,
                      let dstBuf = pcmBuffer.audioBufferList.pointee.mBuffers.mData else {
                    return
                }
                let byteCount = Int(ablPtr.pointee.mBuffers.mDataByteSize)
                dstBuf.copyMemory(from: srcBuf, byteCount: byteCount)
            }
            return pcmBuffer
        } catch {
            log("Error extracting audio buffer list: \(error)")
            return nil
        }
    }
}

// MARK: - ScreenCaptureKit Stream Output Delegate

class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let ringBuffer: AudioRingBuffer
    let converter = AudioFormatConverter()
    var directOutput: Bool  // If true, output directly instead of to ring buffer

    init(ringBuffer: AudioRingBuffer, directOutput: Bool = false) {
        self.ringBuffer = ringBuffer
        self.directOutput = directOutput
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer() else { return }
        guard let samples = converter.convert(pcmBuffer) else { return }

        if directOutput {
            outputPCMToStdout(samples)
        } else {
            ringBuffer.write(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - Microphone Capture via AVAudioEngine

class MicrophoneCapture {
    let engine = AVAudioEngine()
    let ringBuffer: AudioRingBuffer
    let converter = AudioFormatConverter()
    var directOutput: Bool

    init(ringBuffer: AudioRingBuffer, directOutput: Bool = false) {
        self.ringBuffer = ringBuffer
        self.directOutput = directOutput
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available (sample rate = 0)"])
        }

        log("Mic input format: \(inputFormat)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let samples = self.converter.convert(buffer) else { return }
            if self.directOutput {
                outputPCMToStdout(samples)
            } else {
                self.ringBuffer.write(samples)
            }
        }

        engine.prepare()
        try engine.start()
        log("Microphone capture started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Mixer (for dual-source mode)

class AudioMixer {
    let systemBuffer: AudioRingBuffer
    let micBuffer: AudioRingBuffer
    let mixInterval: TimeInterval
    let chunkSize: Int
    var timer: DispatchSourceTimer?

    init(systemBuffer: AudioRingBuffer, micBuffer: AudioRingBuffer) {
        self.systemBuffer = systemBuffer
        self.micBuffer = micBuffer
        // Output ~16000 samples/sec in chunks
        self.chunkSize = 320  // 20ms at 16kHz
        self.mixInterval = Double(chunkSize) / kTargetSampleRate
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: mixInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let sysSamples = self.systemBuffer.read(count: self.chunkSize)
            let micSamples = self.micBuffer.read(count: self.chunkSize)

            // Mix: simple addition with clipping
            var mixed = [Float](repeating: 0, count: self.chunkSize)
            for i in 0..<self.chunkSize {
                mixed[i] = sysSamples[i] + micSamples[i]
            }
            outputPCMToStdout(mixed)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Main

func startSystemAudioCapture(ringBuffer: AudioRingBuffer, directOutput: Bool) async throws -> (SCStream, SystemAudioCapture) {
    // Get shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

    guard let display = content.displays.first else {
        throw NSError(domain: "AudioCapture", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "No display found"])
    }

    log("Using display: \(display.width)x\(display.height)")

    // Create a content filter for the entire display
    let filter = SCContentFilter(display: display,
                                  excludingApplications: [],
                                  exceptingWindows: [])

    // Configure stream: audio-only (minimal video to satisfy API)
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000  // ScreenCaptureKit supports 48kHz natively; we resample later
    config.channelCount = 2

    // Minimal video config to satisfy ScreenCaptureKit's requirement
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimum
    config.showsCursor = false

    let delegate = SystemAudioCapture(ringBuffer: ringBuffer, directOutput: directOutput)
    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)

    // Must add .screen output (ScreenCaptureKit requires it)
    try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .global())
    try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global())

    try await stream.startCapture()
    log("System audio capture started (ScreenCaptureKit)")

    return (stream, delegate)
}

// MARK: - Signal Handling

var shouldRun = true

signal(SIGINT) { _ in
    shouldRun = false
}
signal(SIGTERM) { _ in
    shouldRun = false
}
signal(SIGPIPE) { _ in
    shouldRun = false
}

// MARK: - Entry Point

log("Starting audio capture (mode: \(captureMode))...")
log("Output format: PCM 16-bit signed LE, mono, \(Int(kTargetSampleRate)) Hz")

// Ring buffers: ~2 seconds at 16kHz
let systemRingBuffer = AudioRingBuffer(capacity: Int(kTargetSampleRate) * 2)
let micRingBuffer = AudioRingBuffer(capacity: Int(kTargetSampleRate) * 2)

var scStream: SCStream?
var systemAudioDelegate: SystemAudioCapture?
var micCapture: MicrophoneCapture?
var mixer: AudioMixer?

// Use a semaphore to keep the process alive
let runSemaphore = DispatchSemaphore(value: 0)

Task {
    do {
        switch captureMode {
        case .systemOnly:
            let (stream, delegate) = try await startSystemAudioCapture(
                ringBuffer: systemRingBuffer, directOutput: true)
            scStream = stream
            systemAudioDelegate = delegate

        case .micOnly:
            let mic = MicrophoneCapture(ringBuffer: micRingBuffer, directOutput: true)
            try mic.start()
            micCapture = mic

        case .both:
            // Start both captures writing to their ring buffers
            let (stream, delegate) = try await startSystemAudioCapture(
                ringBuffer: systemRingBuffer, directOutput: false)
            scStream = stream
            systemAudioDelegate = delegate

            let mic = MicrophoneCapture(ringBuffer: micRingBuffer, directOutput: false)
            try mic.start()
            micCapture = mic

            // Start mixer
            let mix = AudioMixer(systemBuffer: systemRingBuffer, micBuffer: micRingBuffer)
            mix.start()
            mixer = mix
        }

        log("Capture running. Press Ctrl+C to stop.")

    } catch {
        log("FATAL: \(error.localizedDescription)")
        exit(1)
    }
}

// Keep running until signal
while shouldRun {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
}

// Cleanup
log("Shutting down...")
mixer?.stop()
micCapture?.stop()
if let stream = scStream {
    let sem = DispatchSemaphore(value: 0)
    Task {
        try? await stream.stopCapture()
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 2)
}
log("Done.")
exit(0)
