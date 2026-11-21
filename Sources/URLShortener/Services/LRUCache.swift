//
//  LRUCache.swift
//  URLShortener
//

/// A fixed-capacity least-recently-used cache.
///
/// All operations are O(1). It is a plain value type with no policy of its own (no TTL, no locking),
/// so it is reusable anywhere: wrap it in an actor or a lock for shared use, and layer expiry or
/// statistics on top, as `RedirectCache` does.
///
/// Reading with `value(for:)` and writing with `setValue(_:for:)` both mark an entry as most recently
/// used. Use `peekValue(for:)` to read without changing the order.
struct LRUCache<Key: Hashable, Value> {
    /// Entries live in an array and are linked by index (no class nodes), which keeps this a true
    /// value type: copies are independent and there are no reference cycles.
    fileprivate struct Slot {
        var key: Key
        var value: Value
        var newer: Int?
        var older: Int?
    }

    let capacity: Int

    private var slots: [Slot?] = []
    private var freeSlots: [Int] = []
    private var slotByKey: [Key: Int] = [:]
    private var newest: Int?
    private var oldest: Int?

    /// - Precondition: `capacity` is greater than zero.
    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { slotByKey.count }
    var isEmpty: Bool { slotByKey.isEmpty }

    func contains(_ key: Key) -> Bool { slotByKey[key] != nil }

    /// Keys from most to least recently used.
    var keysByRecency: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(count)
        var cursor = newest
        while let index = cursor, let slot = slots[index] {
            keys.append(slot.key)
            cursor = slot.older
        }
        return keys
    }

    /// Returns the value for `key` and marks it most recently used.
    mutating func value(for key: Key) -> Value? {
        guard let index = slotByKey[key] else { return nil }
        moveToFront(index)
        return slots[index]?.value
    }

    /// Returns the value for `key` without changing its recency.
    func peekValue(for key: Key) -> Value? {
        guard let index = slotByKey[key] else { return nil }
        return slots[index]?.value
    }

    /// Inserts or updates `key` and marks it most recently used.
    /// - Returns: The entry that was evicted to make room, if any. Updating an existing key never evicts.
    @discardableResult
    mutating func setValue(_ value: Value, for key: Key) -> (key: Key, value: Value)? {
        if let index = slotByKey[key] {
            slots[index]?.value = value
            moveToFront(index)
            return nil
        }

        var evicted: (key: Key, value: Value)?
        if slotByKey.count == capacity, let oldest {
            evicted = removeSlot(at: oldest)
        }

        let slot = Slot(key: key, value: value, newer: nil, older: nil)
        let index: Int
        if let reusable = freeSlots.popLast() {
            slots[reusable] = slot
            index = reusable
        } else {
            slots.append(slot)
            index = slots.count - 1
        }
        slotByKey[key] = index
        pushFront(index)
        return evicted
    }

    /// Removes `key` and returns its value, if it was present.
    @discardableResult
    mutating func removeValue(for key: Key) -> Value? {
        guard let index = slotByKey[key] else { return nil }
        return removeSlot(at: index).value
    }

    /// Removes and returns the least recently used entry.
    @discardableResult
    mutating func removeLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard let oldest else { return nil }
        return removeSlot(at: oldest)
    }

    mutating func removeAll() {
        slots.removeAll()
        freeSlots.removeAll()
        slotByKey.removeAll()
        newest = nil
        oldest = nil
    }

    // MARK: Linked list (by slot index)

    private mutating func removeSlot(at index: Int) -> (key: Key, value: Value) {
        unlink(index)
        guard let slot = slots[index] else { preconditionFailure("LRUCache slot \(index) is empty") }
        slots[index] = nil
        freeSlots.append(index)
        slotByKey[slot.key] = nil
        return (slot.key, slot.value)
    }

    private mutating func moveToFront(_ index: Int) {
        guard newest != index else { return }
        unlink(index)
        pushFront(index)
    }

    private mutating func pushFront(_ index: Int) {
        slots[index]?.newer = nil
        slots[index]?.older = newest
        if let newest { slots[newest]?.newer = index }
        newest = index
        if oldest == nil { oldest = index }
    }

    private mutating func unlink(_ index: Int) {
        guard let slot = slots[index] else { return }
        if let newer = slot.newer { slots[newer]?.older = slot.older } else { newest = slot.older }
        if let older = slot.older { slots[older]?.newer = slot.newer } else { oldest = slot.newer }
        slots[index]?.newer = nil
        slots[index]?.older = nil
    }
}

extension LRUCache.Slot: Sendable where Key: Sendable, Value: Sendable {}
extension LRUCache: Sendable where Key: Sendable, Value: Sendable {}
