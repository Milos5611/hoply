import Foundation

public enum FNV1a {
    public static func hash64<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func hex64<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let value = String(hash64(bytes), radix: 16)
        return String(repeating: "0", count: 16 - value.count) + value
    }
}
