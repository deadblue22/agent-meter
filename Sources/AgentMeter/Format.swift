import Foundation

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.0f MB", v / 1_048_576) }
        return String(format: "%.0f KB", v / 1024)
    }

    static func gigabytes(_ value: UInt64) -> String {
        String(format: "%.1f", Double(value) / 1_073_741_824)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func processes(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(count) processes"
    }
}
