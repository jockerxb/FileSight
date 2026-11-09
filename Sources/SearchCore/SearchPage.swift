import Foundation

public struct NameFingerprint {
    let low: UInt64
    let high: UInt64
    public init(normalized: String) {
        var a: UInt64 = 0, b: UInt64 = 0
        var previous: UInt8?
        for byte in normalized.utf8 {
            if let previous {
                let pair = UInt64(previous) << 8 | UInt64(byte)
                let hash = pair &* 0x9E3779B1
                a |= UInt64(1) << ((hash ^ (hash >> 11)) & 63)
                b |= UInt64(1) << (((hash &* 0x85EBCA77) >> 17) & 63)
            }
            previous = byte
        }
        low = a; high = b
    }
    init(words: [String]) {
        var a: UInt64 = 0, b: UInt64 = 0
        for word in words { let mask = NameFingerprint(normalized: word); a |= mask.low; b |= mask.high }
        low = a; high = b
    }
    func canContain(_ query: NameFingerprint) -> Bool { low & query.low == query.low && high & query.high == query.high }
}

public struct SearchPage {
    public let entries: [FileEntry]
    let fingerprints: [NameFingerprint]
    let phoneticFingerprints: [NameFingerprint]
    public init(entries: [FileEntry]) {
        self.entries = entries
        fingerprints = entries.map { NameFingerprint(normalized: $0.searchableName) }
        phoneticFingerprints = entries.map { NameFingerprint(normalized: $0.searchablePhonetic) }
    }
    init(entries: [FileEntry], fingerprints: [NameFingerprint], phoneticFingerprints: [NameFingerprint]) {
        self.entries = entries
        self.fingerprints = fingerprints
        self.phoneticFingerprints = phoneticFingerprints
    }
}
