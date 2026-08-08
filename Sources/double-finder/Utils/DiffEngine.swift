import Foundation

/// Line-level diff for Compare by Content (TC's file comparison). Myers O(ND)
/// on line arrays, post-processed into aligned display rows where a deletion
/// run and an insertion run between two matches pair up as "changed" lines.
/// Pure logic — unit-tested.
enum DiffEngine {
    enum Row: Equatable {
        case same(left: Int, right: Int)       // 1-based line numbers
        case changed(left: Int, right: Int)
        case leftOnly(left: Int)               // line missing on the right
        case rightOnly(right: Int)             // line missing on the left

        var isDifference: Bool {
            if case .same = self { return false }
            return true
        }
    }

    /// Edit-distance cap: beyond this the greedy search would cost too much
    /// memory/time (trace storage grows with the square of the distance);
    /// fall back to naive positional pairing.
    private static let maxEditDistance = 2_000

    static func diff(left a: [String], right b: [String]) -> [Row] {
        let script = myers(a, b) ?? naive(a, b)
        return pairChanges(script)
    }

    /// Myers greedy diff; returns nil when the edit distance exceeds the cap.
    private static func myers(_ a: [String], _ b: [String]) -> [Row]? {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        // Per-round snapshot trimmed to the k-range that round can touch
        // (±d), so trace memory is O(d²) of the actual distance, not the cap.
        var trace: [[Int]] = []
        var found = false

        outer: for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break outer }
                k += 2
            }
        }
        guard found else { return nil }

        // Backtrack from (n, m) through the recorded V snapshots; trace[d]
        // indexes k as k + d.
        var rows: [Row] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd[d + k - 1] < vd[d + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vd[d + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                rows.append(.same(left: x, right: y)); x -= 1; y -= 1
            }
            if x == prevX { rows.append(.rightOnly(right: y)); y -= 1 }
            else { rows.append(.leftOnly(left: x)); x -= 1 }
        }
        while x > 0, y > 0 { rows.append(.same(left: x, right: y)); x -= 1; y -= 1 }
        return rows.reversed()
    }

    /// Positional fallback for pathological inputs: pair line-by-line, then
    /// tail the longer side.
    private static func naive(_ a: [String], _ b: [String]) -> [Row] {
        var rows: [Row] = []
        let common = min(a.count, b.count)
        for i in 0..<common {
            rows.append(a[i] == b[i] ? .same(left: i + 1, right: i + 1)
                                     : .changed(left: i + 1, right: i + 1))
        }
        for i in common..<a.count { rows.append(.leftOnly(left: i + 1)) }
        for i in common..<b.count { rows.append(.rightOnly(right: i + 1)) }
        return rows
    }

    /// Between two matches Myers emits a deletion run then an insertion run;
    /// pairing them positionally reads as "changed" lines side by side.
    private static func pairChanges(_ script: [Row]) -> [Row] {
        var out: [Row] = []
        var dels: [Int] = []
        var ins: [Int] = []

        func flush() {
            let paired = min(dels.count, ins.count)
            for i in 0..<paired { out.append(.changed(left: dels[i], right: ins[i])) }
            for i in paired..<dels.count { out.append(.leftOnly(left: dels[i])) }
            for i in paired..<ins.count { out.append(.rightOnly(right: ins[i])) }
            dels.removeAll(); ins.removeAll()
        }

        for row in script {
            switch row {
            case .leftOnly(let l): dels.append(l)
            case .rightOnly(let r): ins.append(r)
            case .same:
                flush()
                out.append(row)
            case .changed:
                flush()
                out.append(row)
            }
        }
        flush()
        return out
    }
}
