import Foundation

/// Where Likely keeps its data, for a given home folder (tests pass a temporary one).
public enum LikelyDataPaths {
    /// ~/Library/Application Support/Likely: tools.json, evals, History, debug, the agents' run folder.
    public static func support(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Likely", isDirectory: true)
    }

    /// ~/Library/Logs/Likely: likely.log.
    public static func logs(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Likely", isDirectory: true)
    }

    public static func all(home: String = NSHomeDirectory()) -> [URL] { [support(home: home), logs(home: home)] }
}
