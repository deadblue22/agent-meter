import Darwin
import Foundation

enum DiskSize {
    struct Measurement {
        /// Bytes per bucket; bucket 0 holds everything that was not classified
        var buckets: [UInt64]
        /// Every classified entry: its path relative to the root, its bucket and its size
        var classified: [(path: String, bucket: Int, bytes: UInt64)] = []
    }

    /// Bytes allocated on disk under `path`, the figure `du` reports. A hard-linked file is counted once; symbolic
    /// links are not followed and other volumes are not entered.
    static func of(_ path: String) -> UInt64 {
        measure(path, buckets: 1) { _, _ in nil }.buckets[0]
    }

    /// Walks `root` and sums the allocated bytes into buckets. `classify` is asked about every entry below the root
    /// (path relative to `root`, and whether it is a directory). Returning a bucket assigns the entry, and for a
    /// directory everything under it, to that bucket; returning nil counts the entry in bucket 0 and keeps descending.
    static func measure(_ root: String, buckets: Int,
                        classify: (_ relativePath: String, _ isDirectory: Bool) -> Int?) -> Measurement {
        var result = Measurement(buckets: [UInt64](repeating: 0, count: buckets))
        guard let cRoot = strdup(root) else { return result }
        defer { free(cRoot) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return result }
        defer { fts_close(stream) }

        var seen = Set<UInt64>()
        let rootLength = root.utf8.count + 1
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            // Directories are counted when first visited; the post-order visit and error entries are skipped
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT
                    || info == FTS_DNR,
                  let st = entry.pointee.fts_statp else { continue }
            let isDirectory = info == FTS_D || info == FTS_DNR
            let blocks = UInt64(st.pointee.st_blocks) * 512

            func isRepeatedLink() -> Bool {
                guard !isDirectory, st.pointee.st_nlink > 1 else { return false }
                let key = UInt64(st.pointee.st_ino) ^ (UInt64(UInt32(bitPattern: st.pointee.st_dev)) << 40)
                return !seen.insert(key).inserted
            }

            if entry.pointee.fts_level > 0, let path = entry.pointee.fts_path {
                let length = Int(entry.pointee.fts_pathlen)
                let relative = path.withMemoryRebound(to: UInt8.self, capacity: length) {
                    String(decoding: UnsafeBufferPointer(start: $0 + rootLength, count: max(length - rootLength, 0)),
                           as: UTF8.self)
                }
                if let bucket = classify(relative, isDirectory) {
                    var bytes = blocks
                    if info == FTS_D {
                        bytes = of(String(cString: path))
                        _ = fts_set(stream, entry, FTS_SKIP)
                    } else if isRepeatedLink() {
                        bytes = 0
                    }
                    result.buckets[bucket] += bytes
                    result.classified.append((relative, bucket, bytes))
                    continue
                }
            }
            if !isRepeatedLink() { result.buckets[0] += blocks }
        }
        return result
    }
}
