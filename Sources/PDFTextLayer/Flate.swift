import Compression
import Foundation

/// zlib streams as PDF's FlateDecode uses them. The Compression framework reads and writes raw
/// deflate, so the 2-byte zlib header and the Adler-32 trailer are handled here.
enum Flate {
    static func decode(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 2, (Int(data[0]) << 8 | Int(data[1])) % 31 == 0, data[0] & 0x0F == 8 else {
            throw PDFParseError("not a zlib stream")
        }
        let body = Array(data[2...])
        var output: [UInt8] = []
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PDFParseError("inflate init failed")
        }
        defer { compression_stream_destroy(stream) }

        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        try body.withUnsafeBufferPointer { input in
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: chunk - stream.pointee.dst_size))
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw PDFParseError("inflate failed") }
                // Input used up without an end marker: keep what came out, as readers do
                if stream.pointee.src_size == 0 && stream.pointee.dst_size == chunk { break }
            }
        }
        return output
    }

    static func encode(_ data: [UInt8]) -> [UInt8] {
        let capacity = data.count + data.count / 2 + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let size = data.withUnsafeBufferPointer { input in
            compression_encode_buffer(&deflated, capacity, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        var output: [UInt8] = [0x78, 0x9C]
        output += deflated[0..<size]
        let checksum = adler32(data)
        output += [UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)]
        return output
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < data.count {
            let end = min(index + 5552, data.count)
            for byte in data[index..<end] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
            index = end
        }
        return b << 16 | a
    }

    /// Undoes the PNG predictors (10-15) that xref and object streams use
    static func unpredict(_ data: [UInt8], columns: Int, colors: Int = 1, bitsPerComponent: Int = 8) throws -> [UInt8] {
        let bytesPerPixel = max(1, colors * bitsPerComponent / 8)
        let rowLength = (columns * colors * bitsPerComponent + 7) / 8
        var output: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rowLength)
        var index = 0
        while index + 1 + rowLength <= data.count {
            let filter = data[index]
            var row = Array(data[(index + 1)..<(index + 1 + rowLength)])
            for i in 0..<rowLength {
                let left = i >= bytesPerPixel ? Int(row[i - bytesPerPixel]) : 0
                let up = Int(previous[i])
                let upLeft = i >= bytesPerPixel ? Int(previous[i - bytesPerPixel]) : 0
                let add: Int
                switch filter {
                case 0: add = 0
                case 1: add = left
                case 2: add = up
                case 3: add = (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    add = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
                default: throw PDFParseError("unknown PNG predictor \(filter)")
                }
                row[i] = UInt8((Int(row[i]) + add) & 0xFF)
            }
            output += row
            previous = row
            index += 1 + rowLength
        }
        return output
    }
}
