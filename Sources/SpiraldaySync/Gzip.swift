// gzip (RFC 1952) — 레코드 평문을 암호화하기 전에 압축한다. 시스템 zlib 을 쓴다.
import Foundation
import zlib

enum Gzip {
    struct Failure: Error {
        let message: String
    }

    /// gzip 압축 (mtime 0, 수준 6. 엔진마다 압축 바이트가 같을 필요는 없다 — 푼 평문이 같으면 된다)
    static func compress(_ input: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        var strm = z_stream()
        // windowBits 15 + 16 = gzip 머리 · 꼬리 (mtime 0, 이름 없음)
        guard deflateInit2_(&strm, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure(message: "deflateInit2 실패")
        }
        defer { deflateEnd(&strm) }
        let bound = Int(deflateBound(&strm, uLong(input.count))) + 64
        var out = [UInt8](repeating: 0, count: bound)
        let status: Int32 = input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                strm.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                strm.avail_in = uInt(inBuf.count)
                strm.next_out = outBuf.baseAddress
                strm.avail_out = uInt(outBuf.count)
                return deflate(&strm, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw Failure(message: "deflate 실패 \(status)") }
        out.removeSubrange(Int(strm.total_out)...)
        return out
    }

    /// gzip 풀기. 꼬리의 ISIZE(원래 크기)를 먼저 보고 maxBytes 를 넘으면 풀지 않는다 (압축 폭탄).
    /// 풀어 낸 크기가 ISIZE 와 다르면 (꼬리를 속였으면) 실패.
    static func decompress(_ gz: [UInt8], maxBytes: Int) throws -> [UInt8] {
        guard gz.count >= 18 else { throw Failure(message: "압축 데이터가 너무 짧음") }
        let n = gz.count
        let isize = Int(UInt32(gz[n - 4]) | UInt32(gz[n - 3]) << 8 | UInt32(gz[n - 2]) << 16 | UInt32(gz[n - 1]) << 24)
        guard isize <= maxBytes else { throw Failure(message: "압축을 푼 크기가 너무 큼") }
        var strm = z_stream()
        guard inflateInit2_(&strm, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure(message: "inflateInit2 실패")
        }
        defer { inflateEnd(&strm) }
        // ISIZE + 1 바이트만 잡는다: 그보다 많이 나오면 (꼬리를 작게 속임) 실패
        var out = [UInt8](repeating: 0, count: isize + 1)
        let status: Int32 = gz.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                strm.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                strm.avail_in = uInt(inBuf.count)
                strm.next_out = outBuf.baseAddress
                strm.avail_out = uInt(outBuf.count)
                return inflate(&strm, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw Failure(message: "압축을 풀 수 없음 \(status)") }
        guard Int(strm.total_out) == isize else { throw Failure(message: "크기가 맞지 않음") }
        out.removeLast()
        return out
    }
}
