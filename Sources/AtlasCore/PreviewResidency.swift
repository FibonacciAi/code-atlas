/// A fixed number of reusable GPU slots. Visible items stay resident; only an
/// offscreen least-recently-used item can be replaced. This prevents a viewport
/// larger than the old thumbnail cache from endlessly evicting itself.
public struct PreviewResidency<Key: Hashable> {
    private struct Entry { let slot: Int; var used: UInt64 }
    public let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var visible: Set<Key> = []
    private var clock: UInt64 = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }
    public var count: Int { entries.count }
    public func slot(for key: Key) -> Int? { entries[key]?.slot }
    public var residentKeys: Set<Key> { Set(entries.keys) }

    public mutating func retainVisible(_ keys: [Key]) {
        visible = Set(keys)
        clock &+= 1
        for key in visible where entries[key] != nil { entries[key]?.used = clock }
    }

    /// Returns nil if every slot is pinned. A late, offscreen completion must
    /// never evict an image which the user is still looking at.
    public mutating func insert(_ key: Key) -> Int? {
        clock &+= 1
        if let entry = entries[key] {
            entries[key]?.used = clock
            return entry.slot
        }
        let slot: Int
        if entries.count < capacity {
            let used = Set(entries.values.map(\.slot))
            slot = (0..<capacity).first { !used.contains($0) }!
        } else {
            guard let victim = entries.filter({ !visible.contains($0.key) }).min(by: {
                $0.value.used == $1.value.used ? $0.value.slot < $1.value.slot : $0.value.used < $1.value.used
            }) else { return nil }
            slot = victim.value.slot
            entries.removeValue(forKey: victim.key)
        }
        entries[key] = Entry(slot: slot, used: clock)
        return slot
    }
}
