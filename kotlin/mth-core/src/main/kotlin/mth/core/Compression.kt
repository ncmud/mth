package mth.core

import java.util.zip.Deflater
import java.util.zip.Inflater
import java.util.zip.DataFormatException

class DeflateStream private constructor(private val deflater: Deflater) {
    companion object {
        fun create(): DeflateStream? {
            return try {
                val deflater = Deflater(Deflater.BEST_COMPRESSION)
                DeflateStream(deflater)
            } catch (e: Exception) {
                null
            }
        }
    }

    fun compress(input: ByteArray): ByteArray? {
        return try {
            deflater.setInput(input)
            val output = ByteArray(input.size + 256)
            val count = deflater.deflate(output, 0, output.size, Deflater.SYNC_FLUSH)
            output.copyOf(count)
        } catch (e: Exception) {
            null
        }
    }

    fun finish(): ByteArray? {
        return try {
            deflater.finish()
            val output = ByteArray(256)
            val count = deflater.deflate(output)
            deflater.end()
            output.copyOf(count)
        } catch (e: Exception) {
            null
        }
    }
}

data class InflateResult(
    val decompressed: ByteArray,
    val finished: Boolean,
    val unconsumedInput: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is InflateResult) return false
        return decompressed.contentEquals(other.decompressed)
            && finished == other.finished
            && unconsumedInput.contentEquals(other.unconsumedInput)
    }

    override fun hashCode(): Int {
        var result = decompressed.contentHashCode()
        result = 31 * result + finished.hashCode()
        result = 31 * result + unconsumedInput.contentHashCode()
        return result
    }
}

class InflateStream private constructor(private val inflater: Inflater) {
    companion object {
        fun create(): InflateStream? {
            return try {
                InflateStream(Inflater())
            } catch (e: Exception) {
                null
            }
        }
    }

    fun decompress(input: ByteArray): InflateResult? {
        return try {
            inflater.setInput(input)
            var bufSize = input.size * 4 + 256
            var output = ByteArray(bufSize)
            var totalProduced = 0

            while (true) {
                val count = inflater.inflate(output, totalProduced, output.size - totalProduced)
                totalProduced += count

                if (inflater.finished()) {
                    val remaining = inflater.remaining
                    val unconsumed = if (remaining > 0) {
                        input.copyOfRange(input.size - remaining, input.size)
                    } else {
                        ByteArray(0)
                    }
                    return InflateResult(output.copyOf(totalProduced), true, unconsumed)
                }

                if (count == 0) {
                    // No more output and not finished
                    if (inflater.needsInput()) {
                        val remaining = inflater.remaining
                        val unconsumed = if (remaining > 0) {
                            input.copyOfRange(input.size - remaining, input.size)
                        } else {
                            ByteArray(0)
                        }
                        return InflateResult(output.copyOf(totalProduced), false, unconsumed)
                    }
                    return null // error
                }

                if (totalProduced >= output.size) {
                    bufSize *= 2
                    output = output.copyOf(bufSize)
                }
            }

            @Suppress("UNREACHABLE_CODE")
            null
        } catch (e: DataFormatException) {
            null
        }
    }
}
