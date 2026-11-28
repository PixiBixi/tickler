import Foundation

/// Blocked intervals sorted by start, with the running maximum of their ends.
/// The latest end among intervals starting before `t` answers every overlap query in O(log n).
struct BlockerIndex {
    private var starts: [Date] = []
    private var ends: [Date] = []
    /// `maxEnd[i]` is the latest end among the first `i + 1` intervals.
    private var maxEnd: [Date] = []

    init(_ intervals: [DateInterval] = []) {
        let kept = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        starts = kept.map(\.start)
        ends = kept.map(\.end)
        rebuildMaxEnd(from: 0)
    }

    /// An empty interval blocks nothing, as in the overlap test.
    mutating func insert(_ interval: DateInterval) {
        guard interval.duration > 0 else { return }
        let index = count(startingBefore: interval.start)
        starts.insert(interval.start, at: index)
        ends.insert(interval.end, at: index)
        maxEnd.insert(interval.end, at: index)
        rebuildMaxEnd(from: index)
    }

    /// The latest end among the intervals overlapping `[start, end)`, nil when none does.
    func latestEnd(overlappingFrom start: Date, to end: Date) -> Date? {
        let prefix = count(startingBefore: end)
        guard prefix > 0, maxEnd[prefix - 1] > start else { return nil }
        // The interval holding the prefix maximum starts before `end` and ends after `start`: it overlaps and ends last.
        return maxEnd[prefix - 1]
    }

    /// How many intervals start strictly before `date`.
    private func count(startingBefore date: Date) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private mutating func rebuildMaxEnd(from index: Int) {
        if maxEnd.count != ends.count {
            maxEnd = ends
        }
        for position in index ..< ends.count {
            maxEnd[position] = position == 0 ? ends[position] : max(maxEnd[position - 1], ends[position])
        }
    }
}
