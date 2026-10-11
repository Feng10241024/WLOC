import Foundation
import zlib

struct WLOCRewriteStatistics: Equatable, Sendable {
    var wifiRecords = 0
    var cellularRecords = 0
    var locations = 0
    var skippedRecords = 0
}

struct WLOCResponseRewriteResult: Equatable, Sendable {
    let data: Data
    let matched: Bool
    let statistics: WLOCRewriteStatistics

    /// `true` only when the returned bytes are still gzip encoded. The proxy
    /// uses this to avoid removing Content-Encoding from an untouched body.
    let preservesContentEncoding: Bool
}

/// Rewrites location messages in responses returned by the two explicitly
/// authorized WLOC-compatible test hosts.
///
/// The upstream format has no published `.proto` schema in this project, so
/// the parser intentionally follows the same bounded structural checks as the
/// reference script: Wi-Fi records are identified by a MAC-address field and
/// cellular records by their enclosing field numbers. Unknown protobuf fields
/// are copied byte-for-byte.
struct WLOCProtobufResponseRewriter: Sendable {
    private static let maximumDecodedBytes = 16 * 1_024 * 1_024

    private let hosts: Set<String>

    init(allowedHosts: Set<String>) {
        hosts = allowedHosts.intersection(
            SharedConstants.wlocResponseRewriteHosts
        )
    }

    func rewrite(
        data: Data,
        response: HTTPURLResponse,
        requestURL: URL,
        location: SharedLocationConfiguration
    ) -> WLOCResponseRewriteResult {
        let originalIsGzip = GzipCodec.isGzip(data)
        guard location.isValid,
              location.rewriteEnabled,
              requestURL.scheme?.lowercased() == "https",
              let host = requestURL.host?.lowercased(),
              hosts.contains(host),
              requestURL.path == SharedConstants.wlocResponseRewritePath,
              (200..<300).contains(response.statusCode)
        else {
            return WLOCResponseRewriteResult(
                data: data,
                matched: false,
                statistics: WLOCRewriteStatistics(),
                preservesContentEncoding: originalIsGzip
            )
        }

        let decoded: Data
        if originalIsGzip {
            guard let uncompressed = try? GzipCodec.decompress(
                data,
                maximumOutputBytes: Self.maximumDecodedBytes
            ) else {
                return WLOCResponseRewriteResult(
                    data: data,
                    matched: false,
                    statistics: WLOCRewriteStatistics(),
                    preservesContentEncoding: true
                )
            }
            decoded = uncompressed
        } else {
            guard data.count <= Self.maximumDecodedBytes else {
                return WLOCResponseRewriteResult(
                    data: data,
                    matched: false,
                    statistics: WLOCRewriteStatistics(),
                    preservesContentEncoding: false
                )
            }
            decoded = data
        }

        let bytes = [UInt8](decoded)
        guard let patched = ProtobufWLOCPatcher.patch(
            bytes,
            location: location
        ) else {
            // If an upstream URLSession ever returns raw gzip bytes, return the
            // successfully decoded body because the proxy removes the encoding
            // header before forwarding it to the client.
            return WLOCResponseRewriteResult(
                data: decoded,
                matched: false,
                statistics: WLOCRewriteStatistics(),
                preservesContentEncoding: false
            )
        }
        return WLOCResponseRewriteResult(
            data: Data(patched.bytes),
            matched: true,
            statistics: patched.statistics,
            preservesContentEncoding: false
        )
    }
}

private enum ProtobufWLOCPatcher {
    struct PatchResult {
        let bytes: [UInt8]
        let statistics: WLOCRewriteStatistics
    }

    private struct Field {
        let number: Int
        let wireType: Int
        let valueBytes: [UInt8]?
        let raw: [UInt8]
    }

    private enum ParseError: Error {
        case truncated
        case invalidVarint
        case invalidField
        case unsupportedWireType
        case invalidLength
    }

    static func patch(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration
    ) -> PatchResult? {
        guard bytes.count >= 10 else {
            return patchRaw(bytes, location: location)
        }

        var preferredOffsets = stride(from: 0, through: 16, by: 2)
            .map { $0 }
        let maximumOffset = min(96, max(0, bytes.count - 10))
        for offset in 0...maximumOffset
            where !preferredOffsets.contains(offset) {
            preferredOffsets.append(offset)
        }

        for offset in preferredOffsets {
            guard let result = try? patchFrame(
                bytes,
                offset: offset,
                location: location
            ) else {
                continue
            }
            return result
        }
        return patchRaw(bytes, location: location)
    }

    private static func patchFrame(
        _ bytes: [UInt8],
        offset: Int,
        location: SharedLocationConfiguration
    ) throws -> PatchResult {
        guard offset >= 0, bytes.count >= offset + 10 else {
            throw ParseError.truncated
        }
        let payloadLength = (Int(bytes[offset + 8]) << 8)
            | Int(bytes[offset + 9])
        guard payloadLength > 0,
              offset + 10 + payloadLength <= bytes.count
        else {
            throw ParseError.invalidLength
        }

        let payload = Array(
            bytes[(offset + 10)..<(offset + 10 + payloadLength)]
        )
        var statistics = WLOCRewriteStatistics()
        let patchedPayload = try patchTopLevel(
            payload,
            location: location,
            statistics: &statistics
        )
        guard patchedPayload != payload,
              statistics.locations > 0,
              patchedPayload.count <= Int(UInt16.max)
        else {
            throw ParseError.invalidField
        }

        var result = Array(bytes[..<(offset + 8)])
        result.append(UInt8((patchedPayload.count >> 8) & 0xff))
        result.append(UInt8(patchedPayload.count & 0xff))
        result.append(contentsOf: patchedPayload)
        result.append(
            contentsOf: bytes[(offset + 10 + payloadLength)...]
        )
        return PatchResult(bytes: result, statistics: statistics)
    }

    private static func patchRaw(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration
    ) -> PatchResult? {
        let maximumOffset = min(256, bytes.count)
        for offset in 0...maximumOffset {
            var statistics = WLOCRewriteStatistics()
            let source = Array(bytes[offset...])
            guard let patched = try? patchTopLevel(
                source,
                location: location,
                statistics: &statistics
            ),
                  patched != source,
                  statistics.locations > 0
            else {
                continue
            }
            return PatchResult(
                bytes: Array(bytes[..<offset]) + patched,
                statistics: statistics
            )
        }
        return nil
    }

    private static func patchTopLevel(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration,
        statistics: inout WLOCRewriteStatistics
    ) throws -> [UInt8] {
        let fields = try parseFields(bytes)
        var result: [[UInt8]] = []
        for field in fields {
            guard field.wireType == 2,
                  let value = field.valueBytes
            else {
                result.append(field.raw)
                continue
            }
            if field.number == 2 {
                do {
                    let patched = try patchWiFiRecord(
                        value,
                        location: location,
                        statistics: &statistics
                    )
                    result.append(encodeLengthDelimited(field.number, patched))
                } catch {
                    statistics.skippedRecords += 1
                    result.append(field.raw)
                }
            } else if field.number == 22 || field.number == 24 {
                do {
                    let patched = try patchCellularRecord(
                        value,
                        location: location,
                        statistics: &statistics
                    )
                    result.append(encodeLengthDelimited(field.number, patched))
                } catch {
                    statistics.skippedRecords += 1
                    result.append(field.raw)
                }
            } else {
                result.append(field.raw)
            }
        }
        return flatten(result)
    }

    private static func patchWiFiRecord(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration,
        statistics: inout WLOCRewriteStatistics
    ) throws -> [UInt8] {
        let fields = try parseFields(bytes)
        let hasMACAddress = fields.contains { field in
            field.number == 1
                && field.wireType == 2
                && field.valueBytes.map(isMACAddress) == true
        }
        guard hasMACAddress else {
            return bytes
        }

        var changed = false
        var result: [[UInt8]] = []
        for field in fields {
            guard field.number == 2,
                  field.wireType == 2,
                  let value = field.valueBytes
            else {
                result.append(field.raw)
                continue
            }
            do {
                let patched = try patchLocation(
                    value,
                    location: location
                )
                if patched != value {
                    changed = true
                    statistics.locations += 1
                }
                result.append(encodeLengthDelimited(field.number, patched))
            } catch {
                statistics.skippedRecords += 1
                result.append(field.raw)
            }
        }
        if changed {
            statistics.wifiRecords += 1
        }
        return flatten(result)
    }

    private static func patchCellularRecord(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration,
        statistics: inout WLOCRewriteStatistics
    ) throws -> [UInt8] {
        let fields = try parseFields(bytes)
        var changed = false
        var result: [[UInt8]] = []
        for field in fields {
            guard field.number == 5,
                  field.wireType == 2,
                  let value = field.valueBytes
            else {
                result.append(field.raw)
                continue
            }
            do {
                let patched = try patchLocation(
                    value,
                    location: location
                )
                if patched != value {
                    changed = true
                    statistics.locations += 1
                }
                result.append(encodeLengthDelimited(field.number, patched))
            } catch {
                statistics.skippedRecords += 1
                result.append(field.raw)
            }
        }
        if changed {
            statistics.cellularRecords += 1
        }
        return flatten(result)
    }

    private static func patchLocation(
        _ bytes: [UInt8],
        location: SharedLocationConfiguration
    ) throws -> [UInt8] {
        let fields = try parseFields(bytes)
        let hasLatitude = fields.contains {
            $0.number == 1 && $0.wireType == 0
        }
        let hasLongitude = fields.contains {
            $0.number == 2 && $0.wireType == 0
        }
        guard hasLatitude, hasLongitude else {
            return bytes
        }

        let latitude = javascriptRoundedInt64(location.latitude * 100_000_000)
        let longitude = javascriptRoundedInt64(location.longitude * 100_000_000)
        let accuracy = max(1, Int64(location.accuracy.rounded()))

        return flatten(fields.map { field in
            if field.number == 1, field.wireType == 0 {
                return encodeVarintField(field.number, latitude)
            }
            if field.number == 2, field.wireType == 0 {
                return encodeVarintField(field.number, longitude)
            }
            if field.number == 3, field.wireType == 0 {
                return encodeVarintField(field.number, accuracy)
            }
            return field.raw
        })
    }

    private static func parseFields(_ bytes: [UInt8]) throws -> [Field] {
        var fields: [Field] = []
        var index = 0
        while index < bytes.count {
            let start = index
            let key = try decodeVarint(bytes, index: &index)
            let number = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard number > 0 else {
                throw ParseError.invalidField
            }

            let valueBytes: [UInt8]?
            switch wireType {
            case 0:
                _ = try decodeVarint(bytes, index: &index)
                valueBytes = nil
            case 1:
                guard index <= bytes.count - 8 else {
                    throw ParseError.truncated
                }
                index += 8
                valueBytes = nil
            case 2:
                let rawLength = try decodeVarint(bytes, index: &index)
                guard rawLength <= UInt64(Int.max) else {
                    throw ParseError.invalidLength
                }
                let length = Int(rawLength)
                guard length >= 0,
                      index <= bytes.count - length
                else {
                    throw ParseError.truncated
                }
                valueBytes = Array(bytes[index..<(index + length)])
                index += length
            case 5:
                guard index <= bytes.count - 4 else {
                    throw ParseError.truncated
                }
                index += 4
                valueBytes = nil
            default:
                throw ParseError.unsupportedWireType
            }
            fields.append(
                Field(
                    number: number,
                    wireType: wireType,
                    valueBytes: valueBytes,
                    raw: Array(bytes[start..<index])
                )
            )
        }
        return fields
    }

    private static func decodeVarint(
        _ bytes: [UInt8],
        index: inout Int
    ) throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            guard index < bytes.count else {
                throw ParseError.truncated
            }
            let byte = bytes[index]
            index += 1
            let payload = UInt64(byte & 0x7f)
            if byteIndex == 9, payload > 1 {
                throw ParseError.invalidVarint
            }
            value |= payload << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw ParseError.invalidVarint
    }

    private static func encodeVarintField(
        _ fieldNumber: Int,
        _ value: Int64
    ) -> [UInt8] {
        encodeVarint(UInt64(fieldNumber << 3))
            + encodeVarint(UInt64(bitPattern: value))
    }

    private static func encodeLengthDelimited(
        _ fieldNumber: Int,
        _ value: [UInt8]
    ) -> [UInt8] {
        encodeVarint(UInt64((fieldNumber << 3) | 2))
            + encodeVarint(UInt64(value.count))
            + value
    }

    private static func encodeVarint(_ input: UInt64) -> [UInt8] {
        var value = input
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            result.append(byte)
        } while value != 0
        return result
    }

    private static func javascriptRoundedInt64(_ value: Double) -> Int64 {
        Int64(floor(value + 0.5))
    }

    nonisolated private static func isMACAddress(_ bytes: [UInt8]) -> Bool {
        guard let string = String(bytes: bytes, encoding: .ascii) else {
            return false
        }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else {
            return false
        }
        return parts.allSatisfy { part in
            (1...2).contains(part.count)
                && part.allSatisfy { character in
                    character.isHexDigit
                }
        }
    }

    private static func flatten(_ chunks: [[UInt8]]) -> [UInt8] {
        chunks.flatMap { $0 }
    }
}

private enum GzipCodec {
    enum CodecError: Error {
        case initializationFailed
        case invalidStream
        case outputTooLarge
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f
            && data[data.index(after: data.startIndex)] == 0x8b
    }

    static func decompress(
        _ data: Data,
        maximumOutputBytes: Int
    ) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw CodecError.initializationFailed
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        let status: Int32 = try data.withUnsafeBytes { inputBuffer in
            guard let inputAddress = inputBuffer.bindMemory(
                to: Bytef.self
            ).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
            stream.avail_in = uInt(inputBuffer.count)

            var currentStatus = Int32(Z_OK)
            let chunkSize = 32 * 1_024
            while currentStatus != Z_STREAM_END {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                currentStatus = chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(
                        to: Bytef.self
                    ).baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard currentStatus == Z_OK
                        || currentStatus == Z_STREAM_END
                else {
                    return currentStatus
                }
                let produced = chunkSize - Int(stream.avail_out)
                guard output.count <= maximumOutputBytes - produced else {
                    throw CodecError.outputTooLarge
                }
                output.append(contentsOf: chunk.prefix(produced))
                if produced == 0,
                   stream.avail_in == 0,
                   currentStatus != Z_STREAM_END {
                    return Z_DATA_ERROR
                }
            }
            return currentStatus
        }
        guard status == Z_STREAM_END else {
            throw CodecError.invalidStream
        }
        return output
    }
}
