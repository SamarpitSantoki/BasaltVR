import Foundation

public enum AlvrADBDeviceParser {
    public static func authorizedUSBSerial(from output: String) -> String? {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device",
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
                return nil
            }
            return String(fields[0])
        }.first
    }

    public static func hasUnauthorizedDevice(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).dropFirst().contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "unauthorized"
        }
    }

    public static func installedALVRPackage(from output: String) -> String? {
        let installed = Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst("package:".count)) : nil
        })
        return ["alvr.client", "alvr.client.stable", "alvr.client.dev"]
            .first(where: installed.contains)
    }

    public static func activityIsResumed(from output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .hasPrefix("mResumed=true")
        }
    }
}

public enum AlvrADBExecutableLocator {
    public static let standardFallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = standardFallbackDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var visited = Set<String>()
        for directory in pathDirectories + fallbackDirectories
            where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("adb")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Owns ALVR's native USB setup for one authorized Android headset. `adb forward`
/// exposes the headset's control and stream listeners on localhost;
/// the negotiated wired flag makes ALVR use TCP for stream traffic.
public final class AlvrWiredConnection: @unchecked Sendable {
    public let serial: String
    public let packageName: String
    private let lock = NSLock()
    private var stopped = false

    private init(serial: String, packageName: String) {
        self.serial = serial
        self.packageName = packageName
    }

    public static func setup() throws -> AlvrWiredConnection {
        let devices = try runADB(["devices", "-l"])
        guard let serial = AlvrADBDeviceParser.authorizedUSBSerial(from: devices) else {
            if AlvrADBDeviceParser.hasUnauthorizedDevice(in: devices) {
                throw BasaltError("Quest USB debugging is unauthorized; accept the USB debugging prompt in the headset")
            }
            throw BasaltError("No authorized USB Quest found by adb; connect a data-capable cable and enable Developer Mode")
        }

        let packages = try runADB(["-s", serial, "shell", "pm", "list", "packages"])
        guard let package = AlvrADBDeviceParser.installedALVRPackage(from: packages) else {
            throw BasaltError("No ALVR client package is installed on USB headset \(serial)")
        }

        let ports = [AlvrDiscoveryListener.alvrPort, AlvrVideoStreamSender.defaultPort]
        var forwardedPorts = [UInt16]()
        do {
            for port in ports {
                _ = try runADB(["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"])
                forwardedPorts.append(port)
            }

            // Bringing the activity to the foreground is idempotent and avoids
            // force-stopping a VR-focused client. On Quest, an adb force-stop
            // followed by an immediate relaunch can leave the NativeActivity
            // resumed but temporarily denied HEAD_TRACKER access by Horizon.
            // Wake first: Android otherwise accepts the launch and immediately
            // pauses the activity, leaving ALVR's forwarded ports closed.
            _ = try? runADB(["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            _ = try runADB(["-s", serial, "shell", "monkey", "-p", package, "1"])

            var resumed = false
            for _ in 0..<20 {
                let activity = try runADB([
                    "-s", serial, "shell", "dumpsys", "activity", package,
                ])
                if AlvrADBDeviceParser.activityIsResumed(from: activity) {
                    resumed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard resumed else {
                throw BasaltError(
                    "ALVR is paused behind the Quest lock screen. Put on and unlock the headset, keep the ALVR client open, then try Play VR again.")
            }
        } catch {
            // `setup()` has not returned an owner yet, so roll back any port
            // created before the failing command ourselves.
            for port in forwardedPorts {
                _ = try? runADB(["-s", serial, "forward", "--remove", "tcp:\(port)"])
            }
            throw error
        }
        return AlvrWiredConnection(serial: serial, packageName: package)
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        for port in [AlvrDiscoveryListener.alvrPort, AlvrVideoStreamSender.defaultPort] {
            _ = try? Self.runADB(["-s", serial, "forward", "--remove", "tcp:\(port)"])
        }
    }

    deinit { stop() }

    @discardableResult
    private static func runADB(_ arguments: [String]) throws -> String {
        guard let adb = AlvrADBExecutableLocator.find() else {
            throw BasaltError(
                "Could not find adb; install Android platform-tools "
                    + "(for example: brew install android-platform-tools)")
        }
        let process = Process()
        process.executableURL = adb
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw BasaltError(
                "Could not run adb at \(adb.path): \(error.localizedDescription)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BasaltError("adb \(arguments.joined(separator: " ")) failed"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return output
    }
}
