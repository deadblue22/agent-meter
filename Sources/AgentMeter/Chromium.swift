import Foundation

/// Chrome, and the apps built on Chromium (Electron apps such as Lark, Claude or ChatGPT), split their work over many
/// helper processes. What each one is for is in its command line; which page it shows is not.
enum Chromium {
    /// What a helper process is for, or nil for the main process and for anything that is not a Chromium process
    static func role(_ arguments: [String]) -> String? {
        guard let type = value(of: "--type", in: arguments) else { return nil }
        switch type {
        case "renderer":
            return arguments.contains("--extension-process") ? "Extension renderer" : "Page renderer"
        case "gpu-process":
            return "GPU"
        case "utility":
            guard let service = value(of: "--utility-sub-type", in: arguments) else { return "Utility" }
            switch service {
            case "network.mojom.NetworkService": return "Network service"
            case "storage.mojom.StorageService": return "Storage service"
            case "audio.mojom.AudioService": return "Audio service"
            case "video_capture.mojom.VideoCaptureService": return "Video capture"
            default:
                // "foo.mojom.BarService" is "Bar service"
                let name = service.split(separator: ".").last.map(String.init) ?? service
                return name.replacingOccurrences(of: "Service", with: " service").trimmingCharacters(in: .whitespaces)
            }
        case "crashpad-handler":
            return "Crash reporter"
        default:
            return type.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// The application an executable belongs to: the first `.app` in its path
    static func appName(_ executable: String) -> String? {
        executable.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(".app".count)) }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
    }
}
