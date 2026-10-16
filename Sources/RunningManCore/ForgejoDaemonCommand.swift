import Foundation

/// Identifies a daemon command from public LaunchAgent arguments without opening
/// configuration or registration files. Flag values such as a runner named
/// "daemon" must never be interpreted as the executable's subcommand.
public enum ForgejoDaemonCommand {
    public static func parse(arguments: [String]) -> String? {
        guard arguments.count > 1, arguments.count <= 256,
              arguments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.contains("\0") }) else { return nil }
        let daemonFlags: Set<String> = ["--url", "--uuid", "--token-url", "--label", "--fetch-interval"]
        var foundDaemon = false
        var configuration: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "daemon" {
                guard !foundDaemon else { return nil }
                foundDaemon = true; index += 1; continue
            }
            let pieces = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(pieces[0])
            let isConfig = flag == "--config" || flag == "-c"
            guard isConfig || (foundDaemon && daemonFlags.contains(flag)) else { return nil }
            let value: String
            if pieces.count == 2 {
                value = String(pieces[1]); index += 1
            } else {
                guard index + 1 < arguments.count else { return nil }
                value = arguments[index + 1]; index += 2
            }
            guard !value.isEmpty else { return nil }
            if isConfig {
                guard configuration == nil else { return nil }
                configuration = value
            }
        }
        return foundDaemon ? configuration : nil
    }
}
