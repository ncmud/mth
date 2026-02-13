import CZlib

/// Streaming deflate compressor for MCCP2 (server → client compression).
///
/// Wraps zlib's `deflate` with `Z_SYNC_FLUSH` per call, matching the C
/// implementation's `write_mccp2` behavior.
public final class DeflateStream {

    private var stream: z_stream
    private var initialized = false

    /// Initialize a deflate stream matching MCCP2 parameters.
    /// windowBits=12, memLevel=5, Z_BEST_COMPRESSION.
    public init?() {
        stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let result = deflateInit2_(
            &stream,
            Z_BEST_COMPRESSION,
            Z_DEFLATED,
            12,   // windowBits — 4096 byte window, matches C MCCP2
            5,    // memLevel
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard result == Z_OK else { return nil }
        initialized = true
    }

    deinit {
        if initialized {
            deflateEnd(&stream)
        }
    }

    /// Compress data with Z_SYNC_FLUSH. Returns compressed bytes.
    public func compress(_ input: [UInt8]) -> [UInt8]? {
        guard initialized else { return nil }

        var output = [UInt8](repeating: 0, count: input.count + 256)

        return input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
                stream.avail_in = uInt(input.count)
                stream.next_out = outBuf.baseAddress!
                stream.avail_out = uInt(outBuf.count)

                let result = CZlib.deflate(&stream, Z_SYNC_FLUSH)

                guard result == Z_OK else { return nil }

                let produced = outBuf.count - Int(stream.avail_out)
                return Array(outBuf[..<produced])
            }
        }
    }

    /// Finish the deflate stream. Returns final compressed bytes.
    public func finish() -> [UInt8]? {
        guard initialized else { return nil }

        var output = [UInt8](repeating: 0, count: 256)

        return output.withUnsafeMutableBufferPointer { outBuf in
            stream.next_in = nil
            stream.avail_in = 0
            stream.next_out = outBuf.baseAddress!
            stream.avail_out = uInt(outBuf.count)

            let result = CZlib.deflate(&stream, Z_FINISH)

            guard result == Z_STREAM_END || result == Z_OK else { return nil }

            let produced = outBuf.count - Int(stream.avail_out)
            return Array(outBuf[..<produced])
        }
    }
}

/// Streaming inflate decompressor for MCCP3 (client → server compression).
///
/// Wraps zlib's `inflate` with `Z_SYNC_FLUSH`, matching the C
/// implementation's translate_telopts MCCP3 decompression.
public final class InflateStream {

    private var stream: z_stream
    private var initialized = false

    public init?() {
        stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let result = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard result == Z_OK else { return nil }
        initialized = true
    }

    deinit {
        if initialized {
            inflateEnd(&stream)
        }
    }

    /// Result of an inflate operation.
    public struct Result {
        public let decompressed: [UInt8]
        public let finished: Bool
        /// Bytes of input not yet consumed (remaining after Z_STREAM_END).
        public let unconsumedInput: [UInt8]
    }

    /// Decompress input data. Returns decompressed bytes, whether the stream
    /// ended, and any unconsumed input bytes (trailing uncompressed data
    /// after Z_STREAM_END).
    public func decompress(_ input: [UInt8]) -> Result? {
        guard initialized else { return nil }

        var bufSize = input.count * 4 + 256
        var output = [UInt8](repeating: 0, count: bufSize)
        var totalProduced = 0

        return input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
            stream.avail_in = uInt(input.count)

            while true {
                output.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress! + totalProduced
                    stream.avail_out = uInt(outBuf.count - totalProduced)
                }

                let result = CZlib.inflate(&stream, Z_SYNC_FLUSH)

                let produced = bufSize - totalProduced - Int(stream.avail_out)
                totalProduced += produced

                switch result {
                case Z_OK:
                    if stream.avail_out == 0 {
                        // Output buffer full — grow and retry
                        bufSize *= 2
                        output.append(contentsOf: [UInt8](repeating: 0, count: bufSize - output.count))
                        continue
                    }
                    // All available input consumed or all output produced
                    let unconsumed = Int(stream.avail_in)
                    let unconsumedBytes = unconsumed > 0
                        ? Array(input[(input.count - unconsumed)...])
                        : []
                    return Result(
                        decompressed: Array(output[..<totalProduced]),
                        finished: false,
                        unconsumedInput: unconsumedBytes
                    )

                case Z_STREAM_END:
                    let unconsumed = Int(stream.avail_in)
                    let unconsumedBytes = unconsumed > 0
                        ? Array(input[(input.count - unconsumed)...])
                        : []
                    return Result(
                        decompressed: Array(output[..<totalProduced]),
                        finished: true,
                        unconsumedInput: unconsumedBytes
                    )

                case Z_BUF_ERROR:
                    if stream.avail_out == 0 {
                        bufSize *= 2
                        output.append(contentsOf: [UInt8](repeating: 0, count: bufSize - output.count))
                        continue
                    }
                    return nil // actual error

                default:
                    return nil // error
                }
            }
        }
    }
}
