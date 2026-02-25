import Foundation
import Digest        // leif-ibsen/Digest — transitive dep of SwiftDilithium (SHAKE, XOF)
import BigInt        // leif-ibsen/BigInt — transitive dep of SwiftDilithium (BInt)

// MARK: - ML-DSA-44 Key Expansion
//
// Ports `utils_mldsa.ts` from kohaku/pq-account to Swift.
// The on-chain MLDSA verifier expects an "expanded" public key comprising:
//   • A_hat  — the 4×4 matrix of 256-coefficient polynomials recovered via
//              SHAKE-128 rejection sampling
//   • t1     — 4 polynomials decoded from the compact public key
//   • tr     — SHAKE-256 hash of the raw public key (64 bytes)
//
// The expansion pipeline:
//   rawPK (1312 bytes)
//     → decodePublicKey() → rho (32) + t1 (4×Int32[256])
//     → recoverAHat(rho, K=4, L=4) → A_hat (4×4×Int32[256])
//     → compactModule256(A_hat, m=32) → uint256[4][4][32]
//     → ABI-encode("bytes","bytes","bytes", [aHatEncoded, tr, t1Encoded])
//
// Reference: FIPS 204 §5.2 (ExpandA via RejNTTPoly)

struct MLDSAKeyExpander {

    // ML-DSA-44 parameters
    static let N = 256           // polynomial degree
    static let Q = 8_380_417     // modulus
    static let K = 4             // rows in A
    static let L = 4             // columns in A
    static let D = 13            // dropped bits from t (FIPS 204 §5)
    static let RHO_BYTES = 32    // seed length
    static let T1_POLY_BYTES = 320  // 10 bits × 256 / 8

    /// Version identifier for the key expansion algorithm.
    /// Bump this whenever the expansion logic changes (e.g., NTT fix, ABI encoding change).
    /// Any persisted CREATE2 address derived from an older version is STALE and the
    /// account must be redeployed.
    ///
    /// History:
    ///   "1" — Initial: raw t1 (no NTT). BROKEN on-chain verification.
    ///   "2" — NTT fix: t1 stored as NTT(t1 * 2^D). BROKEN — double-processes t1
    ///         because the on-chain verifier already applies (<< d) + nttFw() itself.
    ///   "3" — Raw t1 fix: t1 stored as plain decoded coefficients. The on-chain
    ///         verifier handles scaling by 2^d and NTT internally in verifyInternal().
    static let expansionVersion = "3"

    // FIPS 204 Appendix B: ζ^{BitRev8(k)} mod Q for k in 0..255
    // Used by the NTT forward transform (Algorithm 41)
    // Sourced from SwiftDilithium / FIPS 204 specification
    private static let nttZetas: [Int64] = [
                   0, 4808194, 3765607, 3761513, 5178923, 5496691, 5234739, 5178987,
             7778734, 3542485, 2682288, 2129892, 3764867, 7375178,  557458, 7159240,
             5010068, 4317364, 2663378, 6705802, 4855975, 7946292,  676590, 7044481,
             5152541, 1714295, 2453983, 1460718, 7737789, 4795319, 2815639, 2283733,
             3602218, 3182878, 2740543, 4793971, 5269599, 2101410, 3704823, 1159875,
              394148,  928749, 1095468, 4874037, 2071829, 4361428, 3241972, 2156050,
             3415069, 1759347, 7562881, 4805951, 3756790, 6444618, 6663429, 4430364,
             5483103, 3192354,  556856, 3870317, 2917338, 1853806, 3345963, 1858416,
             3073009, 1277625, 5744944, 3852015, 4183372, 5157610, 5258977, 8106357,
             2508980, 2028118, 1937570, 4564692, 2811291, 5396636, 7270901, 4158088,
             1528066,  482649, 1148858, 5418153, 7814814,  169688, 2462444, 5046034,
             4213992, 4892034, 1987814, 5183169, 1736313,  235407, 5130263, 3258457,
             5801164, 1787943, 5989328, 6125690, 3482206, 4197502, 7080401, 6018354,
             7062739, 2461387, 3035980,  621164, 3901472, 7153756, 2925816, 3374250,
             1356448, 5604662, 2683270, 5601629, 4912752, 2312838, 7727142, 7921254,
              348812, 8052569, 1011223, 6026202, 4561790, 6458164, 6143691, 1744507,
                1753, 6444997, 5720892, 6924527, 2660408, 6600190, 8321269, 2772600,
             1182243,   87208,  636927, 4415111, 4423672, 6084020, 5095502, 4663471,
             8352605,  822541, 1009365, 5926272, 6400920, 1596822, 4423473, 4620952,
             6695264, 4969849, 2678278, 4611469, 4829411,  635956, 8129971, 5925040,
             4234153, 6607829, 2192938, 6653329, 2387513, 4768667, 8111961, 5199961,
             3747250, 2296099, 1239911, 4541938, 3195676, 2642980, 1254190, 8368000,
             2998219,  141835, 8291116, 2513018, 7025525,  613238, 7070156, 6161950,
             7921677, 6458423, 4040196, 4908348, 2039144, 6500539, 7561656, 6201452,
             6757063, 2105286, 6006015, 6346610,  586241, 7200804,  527981, 5637006,
             6903432, 1994046, 2491325, 6987258,  507927, 7192532, 7655613, 6545891,
             5346675, 8041997, 2647994, 3009748, 5767564, 4148469,  749577, 4357667,
             3980599, 2569011, 6764887, 1723229, 1665318, 2028038, 1163598, 5011144,
             3994671, 8368538, 7009900, 3020393, 3363542,  214880,  545376, 7609976,
             3105558, 7277073,  508145, 7826699,  860144, 3430436,  140244, 6866265,
             6195333, 3123762, 2358373, 6187330, 5365997, 6663603, 2926054, 7987710,
             8077412, 3531229, 4405932, 4606686, 1900052, 7598542, 1054478, 7648983
    ]

    enum ExpanderError: Error {
        case invalidPublicKeyLength(expected: Int, got: Int)
        case coefficientTooLarge(value: Int64, maxBits: Int)
        case totalBitsNotDivisibleBy256
    }

    // MARK: - Public API

    /// Full pipeline: raw ML-DSA-44 public key → ABI-encoded expanded bytes.
    static func toExpandedEncodedBytes(publicKey: [UInt8]) throws -> Data {
        let decoded = try decodePublicKey(publicKey)

        // Recover Â matrix via SHAKE-128 XOF rejection sampling
        let aHat = recoverAHat(rho: decoded.rho, k: K, l: L)

        // Compact to uint256 words
        let aHatCompact = compactModule256(data: aHat, m: 32)

        // The on-chain verifier (ZKNOX_dilithium.sol verifyInternal) handles
        // scaling and NTT itself:
        //   t1New = expandVec(pk.t1)
        //   t1New[i][j] <<= d
        //   t1New[i] = nttFw(t1New[i])
        // So we store the RAW decoded t1 coefficients (10-bit, 0–1023).
        let t1Compact = compactModule256(data: [decoded.t1], m: 32)[0]

        // ABI-encode the three components
        return abiEncodeExpandedKey(
            aHatCompact: aHatCompact,
            tr: decoded.tr,
            t1Compact: t1Compact
        )
    }

    // MARK: - NTT Forward Transform

    /// Modular reduction to [0, Q) for Int64 intermediates.
    private static func modQ64(_ x: Int64) -> Int64 {
        let q = Int64(Q)
        var r = x % q
        if r < 0 { r += q }
        return r
    }

    /// Forward Number Theoretic Transform (FIPS 204, Algorithm 41).
    /// Transforms polynomial coefficients from standard domain to NTT domain.
    /// Input and output coefficients are in [0, Q).
    static func nttForward(_ poly: [Int32]) -> [Int32] {
        assert(poly.count == N)
        var w = poly.map { Int64($0) }
        var m = 0
        var len = 128
        while len >= 1 {
            var start = 0
            while start < N {
                m += 1
                let z = nttZetas[m]
                for j in start..<(start + len) {
                    let t = modQ64(z * w[j + len])
                    w[j + len] = modQ64(w[j] - t)
                    w[j] = modQ64(w[j] + t)
                }
                start += len * 2
            }
            len >>= 1
        }
        return w.map { Int32($0) }
    }

    // MARK: - Decode Public Key

    struct DecodedPublicKey {
        let rho: [UInt8]         // 32 bytes — seed for Â
        let t1: [[Int32]]       // K polynomials, each 256 coefficients (10-bit)
        let tr: [UInt8]          // 64 bytes — SHAKE-256(pk)
    }

    /// Splits the 1312-byte raw ML-DSA-44 public key into rho, t1, and computes tr.
    static func decodePublicKey(_ publicKey: [UInt8]) throws -> DecodedPublicKey {
        let expectedLen = RHO_BYTES + K * T1_POLY_BYTES  // 32 + 4×320 = 1312
        guard publicKey.count == expectedLen else {
            throw ExpanderError.invalidPublicKeyLength(expected: expectedLen, got: publicKey.count)
        }

        let rho = Array(publicKey[0..<RHO_BYTES])

        var t1 = [[Int32]]()
        for i in 0..<K {
            let offset = RHO_BYTES + i * T1_POLY_BYTES
            let polyBytes = Array(publicKey[offset..<(offset + T1_POLY_BYTES)])
            t1.append(polyDecode10Bits(polyBytes))
        }

        // tr = SHAKE-256(publicKey, outputLen=64)
        let tr = shake256Digest(data: publicKey, outputLen: 64)

        return DecodedPublicKey(rho: rho, t1: t1, tr: tr)
    }

    // MARK: - SHAKE-128 Rejection Sampling (ExpandA / RejNTTPoly)

    /// Generates one polynomial of the Â matrix via SHAKE-128 XOF rejection sampling.
    /// Matches the JS: `RejectionSamplePoly(rho, i, j, N=256, q=8380417)`
    ///
    /// Seed construction: `rho || j || i`  (note: j first, then i — per FIPS 204)
    static func rejectionSamplePoly(rho: [UInt8], i: Int, j: Int) -> [Int32] {
        // Build seed: rho (32 bytes) || j (1 byte) || i (1 byte)
        var seed = rho
        seed.append(UInt8(j & 0xFF))
        seed.append(UInt8(i & 0xFF))

        // Create SHAKE-128 XOF (from leif-ibsen/Digest)
        let xof = XOF(.XOF128, seed)

        var r = [Int32](repeating: 0, count: N)
        var jIdx = 0

        while jIdx < N {
            // Read 192 bytes (3 × 64) at a time, matching the JS implementation
            let buf = xof.read(3 * 64)

            var k = 0
            while jIdx < N && k <= buf.count - 3 {
                // Extract 23-bit value from 3 bytes (little-endian)
                var t = Int(buf[k]) | (Int(buf[k + 1]) << 8) | (Int(buf[k + 2]) << 16)
                t &= 0x7FFFFF  // mask to 23 bits

                if t < Q {
                    r[jIdx] = Int32(t)
                    jIdx += 1
                }
                k += 3
            }
        }

        return r
    }

    // MARK: - Recover Â Matrix

    /// Recovers the full K×L matrix Â via rejection sampling from rho.
    static func recoverAHat(rho: [UInt8], k: Int, l: Int) -> [[[Int32]]] {
        var aHat = [[[Int32]]]()
        for i in 0..<k {
            var row = [[Int32]]()
            for j in 0..<l {
                row.append(rejectionSamplePoly(rho: rho, i: i, j: j))
            }
            aHat.append(row)
        }
        return aHat
    }

    // MARK: - Polynomial Decoding (10-bit)

    /// Decodes 320 bytes into a 256-coefficient polynomial where each coefficient is 10 bits.
    /// Uses big-integer bit extraction to match the JS implementation exactly.
    static func polyDecode10Bits(_ bytes: [UInt8]) -> [Int32] {
        var poly = [Int32](repeating: 0, count: N)

        // Accumulate all bytes into a single large integer (little-endian)
        // 320 bytes = 2560 bits, each coefficient = 10 bits → 256 coefficients
        var r = BInt.ZERO
        for i in 0..<bytes.count {
            r = r | (BInt(Int(bytes[i])) << (8 * i))
        }

        let mask = BInt(1023)  // (1 << 10) - 1

        for i in 0..<N {
            let shifted = r >> (i * 10)
            let coeff = shifted & mask
            poly[i] = Int32(coeff.asInt()!)
        }

        return poly
    }

    // MARK: - Compact to uint256 Words

    /// Packs a matrix of polynomials into uint256 words.
    /// Each polynomial (256 coefficients × m bits) → array of uint256 values.
    static func compactModule256(data: [[[Int32]]], m: Int) -> [[[BInt]]] {
        var result = [[[BInt]]]()
        for row in data {
            var rowResult = [[BInt]]()
            for poly in row {
                rowResult.append(compactPoly256(coeffs: poly, m: m))
            }
            result.append(rowResult)
        }
        return result
    }

    /// Packs a single polynomial's coefficients into uint256 words.
    /// `m` = bits per coefficient (must be < 256).
    /// Total bits = 256 × m must be divisible by 256.
    ///
    /// For m=32: each uint256 holds 256/32 = 8 coefficients → 32 uint256s per polynomial.
    static func compactPoly256(coeffs: [Int32], m: Int) -> [BInt] {
        guard m < 256 else {
            fatalError("m must be less than 256")
        }
        guard (coeffs.count * m) % 256 == 0 else {
            fatalError("Total bits must be divisible by 256")
        }

        let maxVal = BInt.ONE << m
        let a: [BInt] = coeffs.map { coeff in
            let val = BInt(Int(coeff))
            guard val < maxVal else {
                fatalError("Element \(coeff) too large for \(m) bits")
            }
            return val
        }

        let n = (a.count * m) / 256
        var b = [BInt](repeating: BInt.ZERO, count: n)

        let coeffsPerWord = 256 / m

        for i in 0..<a.count {
            let idx = (i * m) / 256
            let shift = (i % coeffsPerWord) * m
            b[idx] = b[idx] | (a[i] << shift)
        }

        return b
    }

    // MARK: - ABI Encoding

    /// ABI-encodes the expanded key as: `encode(["bytes","bytes","bytes"], [aHatEncoded, tr, t1Encoded])`
    static func abiEncodeExpandedKey(
        aHatCompact: [[[BInt]]],
        tr: [UInt8],
        t1Compact: [[BInt]]
    ) -> Data {
        // Encode A_hat as uint256[][][] (nested dynamic array)
        let aHatData = abiEncodeUint256Array3D(aHatCompact)

        // Encode t1 as uint256[][] (nested dynamic array)
        let t1Data = abiEncodeUint256Array2D(t1Compact)

        // Final: encode("bytes","bytes","bytes", [aHatEncoded, tr, t1Encoded])
        return ABIEncoder.encode(
            types: [.bytes, .bytes, .bytes],
            values: [.bytes(aHatData), .bytes(Data(tr)), .bytes(t1Data)]
        )
    }

    /// Encodes a 3D array of BInt as ABI uint256[][][]
    /// Matches Solidity's `abi.encode(uint256[][][])` — includes the leading offset word.
    static func abiEncodeUint256Array3D(_ data: [[[BInt]]]) -> Data {
        var encoded = Data()

        // abi.encode wraps dynamic types with a leading offset pointer.
        // For a single dynamic param, offset = 0x20 (32), pointing past this word.
        encoded.append(padTo32(uint256: 32))

        // Outer array length
        encoded.append(padTo32(uint256: data.count))

        // Compute offsets for each row
        var offsets = [Int]()
        var currentOffset = data.count * 32 // past the offset pointers

        for row in data {
            offsets.append(currentOffset)
            currentOffset += computeArray2DSize(row)
        }

        // Write offsets
        for offset in offsets {
            encoded.append(padTo32(uint256: offset))
        }

        // Write each row (2D array)
        for row in data {
            encoded.append(abiEncodeUint256Array2DInner(row))
        }

        return encoded
    }

    /// Encodes a 2D array of BInt as ABI uint256[][]
    /// Matches Solidity's `abi.encode(uint256[][])` — includes the leading offset word.
    static func abiEncodeUint256Array2D(_ data: [[BInt]]) -> Data {
        var encoded = Data()

        // abi.encode wraps dynamic types with a leading offset pointer.
        // For a single dynamic param, offset = 0x20 (32), pointing past this word.
        encoded.append(padTo32(uint256: 32))

        // Outer array length
        encoded.append(padTo32(uint256: data.count))

        // Compute offsets
        var offsets = [Int]()
        var currentOffset = data.count * 32

        for inner in data {
            offsets.append(currentOffset)
            currentOffset += 32 + inner.count * 32 // length + elements
        }

        // Write offsets
        for offset in offsets {
            encoded.append(padTo32(uint256: offset))
        }

        // Write each inner array
        for inner in data {
            encoded.append(padTo32(uint256: inner.count))
            for val in inner {
                encoded.append(bintTo32Bytes(val))
            }
        }

        return encoded
    }

    // Inner version for nested encoding (no outer length prefix since it's part of 3D)
    private static func abiEncodeUint256Array2DInner(_ data: [[BInt]]) -> Data {
        var encoded = Data()

        // Length of this dimension
        encoded.append(padTo32(uint256: data.count))

        // Compute offsets
        var offsets = [Int]()
        var currentOffset = data.count * 32

        for inner in data {
            offsets.append(currentOffset)
            currentOffset += 32 + inner.count * 32
        }

        for offset in offsets {
            encoded.append(padTo32(uint256: offset))
        }

        for inner in data {
            encoded.append(padTo32(uint256: inner.count))
            for val in inner {
                encoded.append(bintTo32Bytes(val))
            }
        }

        return encoded
    }

    private static func computeArray2DSize(_ data: [[BInt]]) -> Int {
        // length word + offset words + (for each inner: length word + element words)
        var size = 32  // outer length
        size += data.count * 32  // offset words
        for inner in data {
            size += 32  // inner length
            size += inner.count * 32  // elements
        }
        return size
    }

    // MARK: - Helpers

    private static func padTo32(uint256 value: Int) -> Data {
        var data = Data(repeating: 0, count: 32)
        var v = value
        // Big-endian uint256
        for i in stride(from: 31, through: 0, by: -1) {
            data[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return data
    }

    /// Converts a BInt to a 32-byte big-endian Data (uint256 encoding).
    static func bintTo32Bytes(_ value: BInt) -> Data {
        // BInt.asMagnitudeBytes() returns big-endian magnitude bytes
        let bytes = value.asMagnitudeBytes()

        // Pad to 32 bytes (big-endian)
        if bytes.count < 32 {
            let padding = Data(repeating: 0, count: 32 - bytes.count)
            return padding + Data(bytes)
        } else if bytes.count > 32 {
            // Truncate to last 32 bytes (should not happen for uint256)
            return Data(bytes.suffix(32))
        }
        return Data(bytes)
    }

    /// SHAKE-256 digest using the Digest library
    private static func shake256Digest(data: [UInt8], outputLen: Int) -> [UInt8] {
        let md = SHAKE(.SHAKE256)
        md.update(data)
        return md.digest(outputLen)
    }
}
