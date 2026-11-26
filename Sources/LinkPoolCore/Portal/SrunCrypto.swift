import Foundation
import CryptoKit

/// Srun (深澜) 4.0 crypto primitives.
///
/// The portal never sends a plaintext password: the client derives an
/// HMAC-MD5 of the password keyed by a per-request challenge token, and wraps
/// the JSON payload in a custom XXTEA + base64 envelope. This file is a
/// byte-exact port of the reference implementation and is covered by
/// differential tests against Python-generated vectors.
public enum SrunCrypto {
    /// Srun's custom base64 alphabet (standard alphabet with +/ swapped for
    /// other characters). Every other character is unchanged.
    public static let base64Alphabet = Array("LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA".utf8)
    private static let standardAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private static let delta: UInt32 = 0x9E37_79B9

    public static func xEncode(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var v = words(from: data, includeLength: true)
        var k = words(from: key, includeLength: false)
        while k.count < 4 { k.append(0) }
        guard v.count > 1 else { return [] }

        let n = v.count - 1
        var z = v[n]
        var d: UInt32 = 0
        var rounds = 6 + 52 / (n + 1)

        while rounds > 0 {
            rounds -= 1
            d = d &+ delta
            let e = (d >> 2) & 3
            for p in 0..<n {
                let y = v[p + 1]
                var m = (z >> 5) ^ (y << 2)
                m = m &+ (((y >> 3) ^ (z << 4)) ^ (d ^ y))
                m = m &+ (k[Int((UInt32(p) & 3) ^ e)] ^ z)
                v[p] = v[p] &+ m
                z = v[p]
            }
            let y = v[0]
            var m = (z >> 5) ^ (y << 2)
            m = m &+ (((y >> 3) ^ (z << 4)) ^ (d ^ y))
            m = m &+ (k[Int((UInt32(n) & 3) ^ e)] ^ z)
            v[n] = v[n] &+ m
            z = v[n]
        }

        var out = [UInt8]()
        out.reserveCapacity(v.count * 4)
        for word in v {
            out.append(UInt8(truncatingIfNeeded: word))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return out
    }

    private static func words(from bytes: [UInt8], includeLength: Bool) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(bytes.count / 4 + (includeLength ? 1 : 0))
        var index = 0
        while index < bytes.count {
            var word: UInt32 = 0
            for offset in 0..<4 {
                let i = index + offset
                if i < bytes.count {
                    word |= UInt32(bytes[i]) << (8 * UInt32(offset))
                }
            }
            result.append(word)
            index += 4
        }
        if includeLength { result.append(UInt32(bytes.count)) }
        return result
    }

    /// Standard base64 with `=` padding, translated into Srun's alphabet.
    public static func customBase64(_ bytes: [UInt8]) -> String {
        let encoded = Data(bytes).base64EncodedString()
        var out = String()
        out.reserveCapacity(encoded.count)
        for ch in encoded {
            guard let ascii = ch.asciiValue, let idx = standardAlphabet.firstIndex(of: ascii) else {
                out.append(ch)
                continue
            }
            out.append(Character(UnicodeScalar(base64Alphabet[idx])))
        }
        return out
    }

    public static func encodeUserInfo(json: String, token: String) -> String {
        let payload = Array(json.utf8)
        let key = Array(token.utf8)
        return "{SRBX1}" + customBase64(xEncode(payload, key: key))
    }

    public static func md5Hex(_ string: String) -> String {
        hex(Insecure.MD5.hash(data: Data(string.utf8)))
    }

    public static func hmacMD5Hex(key: String, message: String) -> String {
        let symmetric = SymmetricKey(data: Data(key.utf8))
        let code = HMAC<Insecure.MD5>.authenticationCode(for: Data(message.utf8), using: symmetric)
        return hex(code)
    }

    public static func sha1Hex(_ string: String) -> String {
        hex(Insecure.SHA1.hash(data: Data(string.utf8)))
    }

    private static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
