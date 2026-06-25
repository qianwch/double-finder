import Foundation

/// Pure planner: splits a file into S3 multipart parts. No I/O, fully testable.
enum S3MultipartPlan {
    struct Part: Equatable { let number: Int; let offset: Int64; let length: Int64 }

    /// Returns [] when `fileSize <= singlePutThreshold` (caller does a single PUT).
    /// Otherwise splits into contiguous parts covering `[0, fileSize)`:
    ///   partSize = max(minPartSize, ceil(fileSize / maxParts) rounded up to 1 MiB),
    /// so the part count never exceeds `maxParts`. The last part carries the remainder.
    static func parts(fileSize: Int64,
                      singlePutThreshold: Int64 = 16 << 20,
                      minPartSize: Int64 = 16 << 20,
                      maxParts: Int = 10_000) -> [Part] {
        guard fileSize > singlePutThreshold else { return [] }
        let mib: Int64 = 1 << 20
        let ceilDivByMax = (fileSize + Int64(maxParts) - 1) / Int64(maxParts)
        let roundedToMiB = ((ceilDivByMax + mib - 1) / mib) * mib
        let partSize = max(minPartSize, roundedToMiB)
        var out: [Part] = []
        var offset: Int64 = 0
        var number = 1
        while offset < fileSize {
            let length = min(partSize, fileSize - offset)
            out.append(Part(number: number, offset: offset, length: length))
            offset += length
            number += 1
        }
        return out
    }
}
