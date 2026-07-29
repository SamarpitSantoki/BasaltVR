import Foundation

public enum SteamConnectionState: Equatable, Sendable {
    case waiting
    case loggedOff
    case loggedOn
}

/// Reads Steam's append-only connection log without treating an old login
/// from a previous client process as readiness for a new cold start.
public enum SteamConnectionLog {
    public static func state(in data: Data, after offset: Int = 0) -> SteamConnectionState {
        let safeOffset = data.count >= offset ? max(0, offset) : 0
        let text = String(decoding: data.dropFirst(safeOffset), as: UTF8.self)
        let loggedOff = text.range(of: "[Logged Off,", options: .backwards)
        let loggedOn = text.range(of: "[Logged On,", options: .backwards)
        switch (loggedOff, loggedOn) {
        case (nil, nil):
            return .waiting
        case (.some, nil):
            return .loggedOff
        case (nil, .some):
            return .loggedOn
        case let (.some(off), .some(on)):
            return on.lowerBound > off.lowerBound ? .loggedOn : .loggedOff
        }
    }
}
