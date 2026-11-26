import Foundation

/// Huawei Agile Controller-Campus portal crypto.
///
/// The page's `do_encrypt_rc4(src, passwd)` is plain RC4 where the key is the
/// decimal millisecond timestamp (`auth_tag`). Output is lowercase hex, one
/// byte per character. We reproduce it exactly (including JS's 2-digit
/// zero-padding rule) so the server sees byte-identical payloads.
public enum HuaweiPortalCrypto {
    public static func rc4Hex(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return "" }
        let keyUnits = Array(key.utf16).map(Int.init)
        let keyLength = keyUnits.count

        var keyStream = [Int](repeating: 0, count: 256)
        var sbox = [Int](repeating: 0, count: 256)
        for i in 0..<256 {
            keyStream[i] = keyUnits[i % keyLength]
            sbox[i] = i
        }

        var j = 0
        for i in 0..<256 {
            j = (j + sbox[i] + keyStream[i]) % 256
            sbox.swapAt(i, j)
        }

        var a = 0, b = 0
        var out = ""
        out.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            a = (a + 1) % 256
            b = (b + sbox[a]) % 256
            sbox.swapAt(a, b)
            let c = (sbox[a] + sbox[b]) % 256
            var hex = String(Int(unit) ^ sbox[c], radix: 16)
            if hex.count == 1 { hex = "0" + hex } else if hex.isEmpty { hex = "00" }
            out += hex
        }
        return out
    }
}
