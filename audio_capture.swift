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
    case auto
}

struct CaptureOptions {
    var mode: CaptureMode = .both
    var appFilter: String? = nil  // 只采集指定应用的音频
    var forceBuiltInMic: Bool = false  // Force built-in mic (for Bluetooth scenarios)
}

// MARK: - Audio Device Detection

/// Detect current output device and resolve auto mode.
/// Always records both system audio + mic (for complete meeting transcription).
/// Key behavior:
/// - Bluetooth output → both mode + force built-in mic (avoid HFP degradation)
/// - Built-in speaker → both mode (some echo, but captures all voices)
/// - Wired headphones / USB → both mode (clean, no issues)
func resolveAutoMode(_ options: inout CaptureOptions) {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr else {
        log("Cannot detect output device, defaulting to both mode")
        options.mode = .both
        return
    }

    // Get transport type
    var transportType: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyTransportType
    let tStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
    guard tStatus == noErr else {
        log("Cannot detect transport type, defaulting to both mode")
        options.mode = .both
        return
    }

    // Get device name for logging
    var nameRef: CFString = "" as CFString
    size = UInt32(MemoryLayout<CFString>.size)
    address.mSelector = kAudioObjectPropertyName
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
    let deviceName = nameRef as String

    switch transportType {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        log("Detected Bluetooth output: \(deviceName) → both mode + forced built-in mic")
        options.mode = .both
        options.forceBuiltInMic = true
    case kAudioDeviceTransportTypeBuiltIn:
        // Built-in could be speakers or headphone jack — check data source
        var dataSource: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDataSource
        address.mScope = kAudioDevicePropertyScopeOutput
        let dsStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &dataSource)
        if dsStatus == noErr && dataSource == fourCharCode("hdpn") {
            log("Detected wired headphones (built-in jack): \(deviceName) → both mode")
        } else {
            log("Detected built-in speaker: \(deviceName) → both mode (mic may pick up echo)")
        }
        options.mode = .both
    case kAudioDeviceTransportTypeUSB:
        log("Detected USB audio: \(deviceName) → both mode")
        options.mode = .both
    default:
        log("Detected output device: \(deviceName) (transport=\(transportType)) → both mode")
        options.mode = .both
    }
}

/// Find the built-in microphone device ID (for use when Bluetooth is active).
func getBuiltInMicDeviceID() -> AudioDeviceID? {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize)
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices)

    for device in devices {
        // Check transport type — must be built-in
        var transportType: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tStatus = AudioObjectGetPropertyData(device, &tAddr, 0, nil, &tSize, &transportType)
        guard tStatus == noErr, transportType == kAudioDeviceTransportTypeBuiltIn else { continue }

        // Check if this device has input channels
        var inputSize: UInt32 = 0
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(device, &inputAddr, 0, nil, &inputSize)
        guard inputSize > 0 else { continue }

        let ablData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(inputSize))
        defer { ablData.deallocate() }
        let ablStatus = AudioObjectGetPropertyData(device, &inputAddr, 0, nil, &inputSize, ablData)
        guard ablStatus == noErr else { continue }

        let abl = ablData.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { $0.pointee }
        if abl.mBuffers.mNumberChannels > 0 {
            // Get device name for logging
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &nameSize, &nameRef)
            log("Found built-in mic: \(nameRef as String) (ID: \(device))")
            return device
        }
    }
    return nil
}

/// Convert a 4-character string to its UInt32 FourCharCode representation
func fourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) | UInt32(char)
    }
    return result
}

func parseArgs() -> CaptureOptions {
    let args = CommandLine.arguments
    var options = CaptureOptions()

    if args.contains("--auto") { options.mode = .auto }
    else if args.contains("--system-only") { options.mode = .systemOnly }
    else if args.contains("--mic-only") { options.mode = .micOnly }

    if let idx = args.firstIndex(of: "--app"), idx + 1 < args.count {
        options.appFilter = args[idx + 1]
    }

    if args.contains("--help") || args.contains("-h") {
        FileHandle.standardError.write(Data("""
        Usage: audio_capture [OPTIONS]

        Captures system audio and/or microphone, outputs raw PCM to stdout.
        Format: 16-bit signed LE, mono, 16000 Hz

        Options:
          --auto              Auto-detect output device and choose best mode (recommended)
          --system-only       Capture system audio only (no microphone)
          --mic-only          Capture microphone only (no system audio)
          --app <name>        Only capture audio from the specified app (e.g. "Zoom", "Chrome")
          --list-apps         List running apps that can be captured
          --help, -h          Show this help message

        Auto mode behavior:
          Bluetooth output  → system-only (avoids HFP mic quality degradation)
          Built-in speaker  → system-only (avoids echo from speakers)
          Wired headphones  → both (system audio + microphone)
          USB audio         → both (system audio + microphone)

        Requires Screen Recording permission for system audio capture.
        Requires Microphone permission for mic capture.

        """.utf8))
        exit(0)
    }

    return options
}

var captureOptions = parseArgs()
if captureOptions.mode == .auto {
    resolveAutoMode(&captureOptions)
}
let captureMode = captureOptions.mode

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
            converter!.sampleRateConverterQuality = AVAudioQuality.max.rawValue
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
    var forceBuiltInMic: Bool

    init(ringBuffer: AudioRingBuffer, directOutput: Bool = false, forceBuiltInMic: Bool = false) {
        self.ringBuffer = ringBuffer
        self.directOutput = directOutput
        self.forceBuiltInMic = forceBuiltInMic
    }

    func start() throws {
        // If Bluetooth is active, force built-in mic to avoid HFP quality degradation
        if forceBuiltInMic {
            if let builtInID = getBuiltInMicDeviceID() {
                let inputNode = engine.inputNode
                guard let audioUnit = inputNode.audioUnit else {
                    throw NSError(domain: "AudioCapture", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot access audio unit on input node"])
                }
                var deviceID = builtInID
                let setStatus = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if setStatus == noErr {
                    log("Forced mic input to built-in device (ID: \(builtInID))")
                } else {
                    log("Warning: failed to set built-in mic (status: \(setStatus)), using default")
                }
            } else {
                log("Warning: built-in mic not found, using default input device")
            }
        }

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
        log("Microphone capture started\(forceBuiltInMic ? " (built-in mic forced)" : "")")
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

            // Mix: attenuate each source to prevent clipping
            var mixed = [Float](repeating: 0, count: self.chunkSize)
            for i in 0..<self.chunkSize {
                mixed[i] = sysSamples[i] * 0.85 + micSamples[i] * 0.85
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

func listRunningApps() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        log("Running apps with audio:")
        for app in content.applications {
            let name = app.applicationName
            let bundleID = app.bundleIdentifier
            if !name.isEmpty {
                FileHandle.standardError.write(Data("  \(name) (\(bundleID))\n".utf8))
            }
        }
    } catch {
        log("无法获取应用列表，请检查屏幕录制权限: \(error.localizedDescription)")
        exit(1)
    }
}

func startSystemAudioCapture(ringBuffer: AudioRingBuffer, directOutput: Bool, appFilter: String? = nil) async throws -> (SCStream, SystemAudioCapture) {
    // Get shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

    guard let display = content.displays.first else {
        throw NSError(domain: "AudioCapture", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "No display found"])
    }

    log("Using display: \(display.width)x\(display.height)")

    // Create content filter — optionally scoped to a specific app
    let filter: SCContentFilter
    if let appName = appFilter {
        let matchedApps = content.applications.filter { app in
            let name = app.applicationName
            // 精确匹配应用名称（忽略大小写），或应用名以关键字开头
            // 排除系统辅助进程（名称中含括号的，如 "Open and Save Panel Service (Lark)"）
            return name.localizedCaseInsensitiveCompare(appName) == .orderedSame
                || name.lowercased().hasPrefix(appName.lowercased())
        }
        guard !matchedApps.isEmpty else {
            log("No running app matching '\(appName)'. Use --list-apps to see available apps.")
            exit(1)
        }
        for app in matchedApps {
            log("Filtering audio to: \(app.applicationName) (\(app.bundleIdentifier))")
        }
        filter = SCContentFilter(display: display,
                                  including: matchedApps,
                                  exceptingWindows: [])
    } else {
        filter = SCContentFilter(display: display,
                                  excludingApplications: [],
                                  exceptingWindows: [])
    }

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

// Handle --list-apps before starting capture
if CommandLine.arguments.contains("--list-apps") {
    Task {
        await listRunningApps()
        exit(0)
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
    exit(0)
}

log("Starting audio capture (mode: \(captureMode))...")
if let app = captureOptions.appFilter {
    log("App filter: \(app)")
}
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
        case .auto:
            fatalError("auto mode should have been resolved before this point")

        case .systemOnly:
            let (stream, delegate) = try await startSystemAudioCapture(
                ringBuffer: systemRingBuffer, directOutput: true, appFilter: captureOptions.appFilter)
            scStream = stream
            systemAudioDelegate = delegate

        case .micOnly:
            let mic = MicrophoneCapture(ringBuffer: micRingBuffer, directOutput: true,
                                         forceBuiltInMic: captureOptions.forceBuiltInMic)
            try mic.start()
            micCapture = mic

        case .both:
            // Start both captures writing to their ring buffers
            let (stream, delegate) = try await startSystemAudioCapture(
                ringBuffer: systemRingBuffer, directOutput: false, appFilter: captureOptions.appFilter)
            scStream = stream
            systemAudioDelegate = delegate

            let mic = MicrophoneCapture(ringBuffer: micRingBuffer, directOutput: false,
                                         forceBuiltInMic: captureOptions.forceBuiltInMic)
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
