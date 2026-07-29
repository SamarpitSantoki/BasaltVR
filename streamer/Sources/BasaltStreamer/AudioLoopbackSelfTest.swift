import Foundation
import AVFoundation
import AudioToolbox
import BasaltCore

enum AudioLoopbackSelfTest {
    private final class Measurement: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var squareSum = 0.0
        private var peak: Int16 = 0

        func consume(_ pcm: Data) {
            let bytes = [UInt8](pcm)
            guard bytes.count.isMultiple(of: 4) else { return }
            lock.lock()
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let sample = Int16(bitPattern: bits)
                let normalized = Double(sample) / 32_768
                squareSum += normalized * normalized
                peak = max(peak, Int16(min(Int(Int16.max), abs(Int(sample)))))
            }
            frames += bytes.count / 4
            lock.unlock()
        }

        func result() -> (frames: Int, rms: Double, peak: Int16) {
            lock.lock()
            defer { lock.unlock() }
            let samples = max(1, frames * 2)
            return (frames, sqrt(squareSum / Double(samples)), peak)
        }
    }

    static func run(_ arguments: [String]) {
        do {
            var deviceName = "BlackHole 2ch"
            var remaining = arguments
            while !remaining.isEmpty {
                let flag = remaining.removeFirst()
                guard flag == "--device", !remaining.isEmpty else {
                    throw BasaltError(
                        "usage: basalt-streamer audio-loopback-selftest [--device NAME]")
                }
                deviceName = remaining.removeFirst()
            }

            let capture = try GameAudioCapture(deviceNameContains: deviceName)
            let measurement = Measurement()
            capture.onPCM16 = { measurement.consume($0) }

            let outputEngine = AVAudioEngine()
            let outputNode = outputEngine.outputNode
            guard let audioUnit = outputNode.audioUnit else {
                throw BasaltError("CoreAudio did not expose an output audio unit")
            }
            var deviceID = AudioDeviceID(capture.device.id)
            let status = AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw BasaltError(
                    "Could not select '\(capture.device.name)' for tone output (status \(status))")
            }

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: GameAudioCapture.sampleRate,
                channels: GameAudioCapture.channelCount,
                interleaved: false),
                  let tone = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(GameAudioCapture.sampleRate)),
                  let channels = tone.floatChannelData else {
                throw BasaltError("Could not allocate the BlackHole tone buffer")
            }
            tone.frameLength = tone.frameCapacity
            for frame in 0..<Int(tone.frameLength) {
                let value = Float(sin(2 * Double.pi * 440
                    * Double(frame) / GameAudioCapture.sampleRate) * 0.2)
                channels[0][frame] = value
                channels[1][frame] = value
            }

            let player = AVAudioPlayerNode()
            outputEngine.attach(player)
            outputEngine.connect(player, to: outputEngine.mainMixerNode, format: format)
            outputEngine.prepare()
            try capture.start()
            try outputEngine.start()
            player.scheduleBuffer(tone, at: nil, options: [.loops])
            player.play()
            Thread.sleep(forTimeInterval: 2)
            player.stop()
            outputEngine.stop()
            capture.stop()

            let result = measurement.result()
            guard result.frames >= 24_000, result.rms > 0.05,
                  result.peak > 2_000 else {
                throw BasaltError(
                    "BlackHole loopback signal was missing or too quiet: "
                        + "\(result.frames) frames, RMS "
                        + String(format: "%.4f", result.rms)
                        + ", peak \(result.peak)")
            }
            print("PASS: \(capture.device.name) captured \(result.frames) stereo frames "
                  + "at 48000 Hz (440 Hz tone, RMS "
                  + String(format: "%.4f", result.rms)
                  + ", peak \(result.peak))")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
