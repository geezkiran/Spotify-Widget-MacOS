import AppKit
import CoreAudio
import os

/// Live loudness of Spotify's audio in three bands (bass, mids, treble), read by tapping its output with a
/// Core Audio process tap. The tap only listens: Spotify keeps playing through the speakers as usual.
///
/// Needs macOS 14.2 or later and the System Audio Recording permission, which macOS asks for on first use.
/// `levels()` is nil while nothing is tapped, so callers can fall back to something else.
final class AudioLevelMonitor: @unchecked Sendable {
    static let shared = AudioLevelMonitor()
    static let bandCount = 3

    /// Written on the audio thread, read by the view every frame.
    private let output = OSAllocatedUnfairLock<SIMD3<Float>?>(initialState: nil)
    private let queue = DispatchQueue(label: "AudioLevelMonitor", qos: .userInteractive)
    private let analyzer = BandAnalyzer()

    private var active = false
    private var session: AnyObject?
    private var retry: Timer?

    /// Smoothed 0...1 level per band (bass, mids, treble), or nil while not tapping.
    func levels() -> SIMD3<Float>? { output.withLock { $0 } }

    /// Starts tapping while active, stops when not. Retries while active, because Spotify only shows up
    /// as an audio process once it has started playing.
    @MainActor
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active {
            start()
        } else {
            stop()
        }
    }

    @MainActor
    private func start() {
        guard active, session == nil else { return }
        guard #available(macOS 14.2, *) else { return }
        do {
            analyzer.reset()
            session = try TapSession(queue: queue) { [analyzer, output] buffers, sampleRate in
                let levels = analyzer.process(buffers, sampleRate: sampleRate)
                output.withLock { $0 = levels }
            }
            retry?.invalidate()
            retry = nil
        } catch {
            Logger.audio.debug("Tap not ready: \(error.localizedDescription, privacy: .public)")
            guard retry == nil else { return }
            retry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        }
    }

    @MainActor
    private func stop() {
        retry?.invalidate()
        retry = nil
        session = nil
        output.withLock { $0 = nil }
    }
}

private extension Logger {
    static let audio = Logger(subsystem: "com.kiran.spotifywidget", category: "audio")
}

// MARK: - Analysis

/// Splits the signal into bands with one-pole filters and follows each band's loudness.
/// Each band is scaled against its own recent peak, so quiet songs and quiet bands still move the bars,
/// and a kick drum pumps the bass bar while hi-hats flicker the treble one.
private final class BandAnalyzer: @unchecked Sendable {
    /// Crossovers between bass and mids, and mids and treble, in Hz.
    private static let crossovers: (Float, Float) = (220, 2400)
    /// Stiffness of the spring each bar rides on, in radians per second: stiff on the way up so a beat shows
    /// at once, softer on the way down so the bar sinks gently. The spring is critically damped, so it never
    /// overshoots, and its speed changes smoothly, so it glides without the delay of stacked filters.
    private static let rise: Float = 55
    private static let fall: Float = 11
    /// How long a band's peak takes to fade, in seconds, so the scaling adapts to the song.
    private static let peakFade: Float = 10
    /// The share of a band's peak that counts as its resting level. Only sound above it lifts the bar,
    /// so a steady mix sits low and beats stand out.
    private static let threshold: Float = 0.4
    /// Below this the band counts as silent, so noise isn't scaled up into movement.
    private static let floor: Float = 0.0015

    // Only touched on the audio queue. SIMD values, so a callback never allocates.
    private var lowState: Float = 0
    private var midState: Float = 0
    private var position = SIMD3<Float>()
    private var velocity = SIMD3<Float>()
    private var peak = SIMD3<Float>()
    /// Filter coefficients for `coefRate`, recomputed only when the sample rate changes.
    private var coefRate: Float = 0
    private var lowCoef: Float = 0
    private var midCoef: Float = 0

    func reset() {
        lowState = 0
        midState = 0
        position = .init()
        velocity = .init()
        peak = .init()
    }

    /// Advances a critically damped spring exactly, so it stays stable whatever the buffer size.
    private func spring(_ band: Int, toward target: Float, omega: Float, dt: Float) {
        let offset = position[band] - target
        let k = velocity[band] + omega * offset
        let decay = exp(-omega * dt)
        position[band] = min(1, max(0, target + (offset + k * dt) * decay))
        velocity[band] = (velocity[band] - omega * k * dt) * decay
    }

    func process(_ list: UnsafeMutableAudioBufferListPointer, sampleRate: Double) -> SIMD3<Float> {
        let rate = Float(sampleRate > 0 ? sampleRate : 48_000)
        if rate != coefRate {
            coefRate = rate
            lowCoef = 1 - exp(-2 * .pi * Self.crossovers.0 / rate)
            midCoef = 1 - exp(-2 * .pi * Self.crossovers.1 / rate)
        }
        let lowCoef = self.lowCoef, midCoef = self.midCoef
        var low = lowState, mid = midState
        var energy = SIMD3<Float>()

        @inline(__always) func step(_ sample: Float) {
            low += lowCoef * (sample - low)
            mid += midCoef * (sample - mid)
            let bands = SIMD3<Float>(low, mid - low, sample - mid)
            energy += bands * bands
        }

        var frames = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if channels == 1 {
                for frame in 0..<count { step(data[frame]) }
            } else {
                let scale = 1 / Float(channels)
                for frame in 0..<count {
                    var sample: Float = 0
                    for channel in 0..<channels { sample += data[frame * channels + channel] }
                    step(sample * scale)
                }
            }
            frames = max(frames, count)
        }
        lowState = low
        midState = mid
        guard frames > 0 else { return position }

        let dt = Float(frames) / rate
        let rms = (energy / Float(frames)).squareRoot()
        let fade = exp(-dt / Self.peakFade)

        for band in 0..<AudioLevelMonitor.bandCount {
            peak[band] = max(rms[band], peak[band] * fade, Self.floor * 4)
            let relative = rms[band] / peak[band]
            let target = rms[band] < Self.floor ? 0 : max(0, min(1, (relative - Self.threshold) / (1 - Self.threshold)))
            spring(band, toward: target, omega: target > position[band] ? Self.rise : Self.fall, dt: dt)
        }
        return position
    }
}

// MARK: - Tap

/// A private tap on Spotify's processes, wired into a private aggregate device so its audio can be read.
/// Torn down on deinit.
@available(macOS 14.2, *)
private final class TapSession {
    typealias Handler = (UnsafeMutableAudioBufferListPointer, Double) -> Void
    /// IO buffer requested for the aggregate: about 21 ms at 48 kHz, well under one 30 fps frame,
    /// with far fewer wake-ups than the device default.
    private static let bufferFrames: UInt32 = 1024

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(queue: DispatchQueue, handler: @escaping Handler) throws {
        let processes = try Self.spotifyProcesses()
        guard !processes.isEmpty else { throw TapError("Spotify isn't producing audio yet") }

        let description = CATapDescription(monoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        do {
            let format: AudioStreamBasicDescription = try Self.property(tapID, kAudioTapPropertyFormat)
            let outputUID = try Self.defaultOutputUID()
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Spotify Widget Levels",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    // The tap runs on the output device's clock, which is also the main sub-device's, so
                    // there's no drift to compensate for, and coreaudiod skips resampling the tap.
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "create aggregate device")

            var bufferFrames = Self.bufferFrames
            var bufferAddress = Self.address(kAudioDevicePropertyBufferFrameSize)
            let bufferStatus = AudioObjectSetPropertyData(aggregateID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames)
            if bufferStatus != noErr {
                Logger.audio.debug("Couldn't set tap buffer size (\(bufferStatus))")
            }

            let sampleRate = format.mSampleRate
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                handler(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), sampleRate)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "start device")
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Spotify plays from its main process or a helper, so tap every process with its bundle ID prefix.
    private static func spotifyProcesses() throws -> [AudioObjectID] {
        let all: [AudioObjectID] = try propertyArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return all.filter { process in
            guard let bundleID = try? string(process, kAudioProcessPropertyBundleID) else { return false }
            return bundleID.hasPrefix("com.spotify.client")
        }
    }

    private static func defaultOutputUID() throws -> String {
        let device: AudioObjectID = try property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return try string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value), "read property")
        return value.pointee
    }

    private static func propertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "read property size")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, values), "read property")
        return Array(UnsafeBufferPointer(start: values, count: Int(size) / MemoryLayout<T>.stride))
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read string")
        guard let value else { throw TapError("Empty string property") }
        return value.takeRetainedValue() as String
    }
}

private struct TapError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw TapError("Couldn't \(step) (\(status))") }
}
