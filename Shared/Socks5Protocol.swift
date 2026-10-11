#if LEGACY_LOCAL_SOCKS
import Foundation
import Network

enum Socks5Command: UInt8, Equatable, Sendable {
    case connect = 0x01
    case udpAssociate = 0x03
}

struct Socks5Destination: Equatable, Sendable {
    enum Host: Equatable, Sendable {
        case ipv4(Data)
        case domain(String)
        case ipv6(Data)
    }

    let host: Host
    let port: UInt16

    var networkHost: NWEndpoint.Host? {
        switch host {
        case let .ipv4(data):
            guard let address = IPv4Address(data) else {
                return nil
            }
            return .ipv4(address)
        case let .domain(name):
            return NWEndpoint.Host(name)
        case let .ipv6(data):
            guard let address = IPv6Address(data) else {
                return nil
            }
            return .ipv6(address)
        }
    }

    var displayHost: String {
        switch host {
        case let .ipv4(data):
            return data.map(String.init).joined(separator: ".")
        case let .domain(name):
            return name
        case let .ipv6(data):
            return IPv6Address(data)?.debugDescription ?? "invalid-ipv6"
        }
    }
}

struct Socks5Request: Equatable, Sendable {
    let command: Socks5Command
    let destination: Socks5Destination
}

struct Socks5UDPDatagram: Equatable, Sendable {
    let destination: Socks5Destination
    let payload: Data
    let responseHeader: Data
}

enum Socks5ParseResult<Value> {
    case incomplete
    case success(value: Value, consumed: Int)
    case invalid
}

enum Socks5ProtocolCodec {
    static func parseGreeting(_ data: Data) -> Socks5ParseResult<Bool> {
        guard data.count >= 2 else {
            return .incomplete
        }
        guard data[0] == 0x05 else {
            return .invalid
        }
        let methodCount = Int(data[1])
        guard data.count >= 2 + methodCount else {
            return .incomplete
        }
        let supportsNoAuthentication = data[2..<(2 + methodCount)].contains(0x00)
        return .success(
            value: supportsNoAuthentication,
            consumed: 2 + methodCount
        )
    }

    static func parseRequest(_ data: Data) -> Socks5ParseResult<Socks5Request> {
        guard data.count >= 4 else {
            return .incomplete
        }
        guard data[0] == 0x05,
              data[2] == 0x00,
              let command = Socks5Command(rawValue: data[1])
        else {
            return .invalid
        }

        switch parseDestination(data, addressTypeOffset: 3) {
        case .incomplete:
            return .incomplete
        case .invalid:
            return .invalid
        case let .success(value, consumed):
            return .success(
                value: Socks5Request(command: command, destination: value),
                consumed: consumed
            )
        }
    }

    static func parseUDPDatagram(_ data: Data) -> Socks5ParseResult<Socks5UDPDatagram> {
        guard data.count >= 4 else {
            return .incomplete
        }
        guard data[0] == 0x00, data[1] == 0x00, data[2] == 0x00 else {
            return .invalid
        }

        switch parseDestination(data, addressTypeOffset: 3) {
        case .incomplete:
            return .incomplete
        case .invalid:
            return .invalid
        case let .success(destination, consumed):
            let payload = Data(data.dropFirst(consumed))
            guard !payload.isEmpty else {
                return .invalid
            }
            return .success(
                value: Socks5UDPDatagram(
                    destination: destination,
                    payload: payload,
                    responseHeader: Data(data.prefix(consumed))
                ),
                consumed: data.count
            )
        }
    }

    static func reply(code: UInt8, port: UInt16) -> Data {
        var data = Data([
            0x05,
            code,
            0x00,
            0x04
        ])
        data.append(Data(repeating: 0, count: 15))
        data.append(0x01)
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xff))
        return data
    }

    private static func parseDestination(
        _ data: Data,
        addressTypeOffset: Int
    ) -> Socks5ParseResult<Socks5Destination> {
        guard data.count > addressTypeOffset else {
            return .incomplete
        }
        let addressType = data[addressTypeOffset]
        var cursor = addressTypeOffset + 1
        let host: Socks5Destination.Host

        switch addressType {
        case 0x01:
            guard data.count >= cursor + 4 + 2 else {
                return .incomplete
            }
            host = .ipv4(Data(data[cursor..<(cursor + 4)]))
            cursor += 4
        case 0x03:
            guard data.count > cursor else {
                return .incomplete
            }
            let length = Int(data[cursor])
            cursor += 1
            guard length > 0, data.count >= cursor + length + 2 else {
                return length == 0 ? .invalid : .incomplete
            }
            guard let name = String(
                data: data[cursor..<(cursor + length)],
                encoding: .utf8
            ), !name.isEmpty else {
                return .invalid
            }
            host = .domain(name.lowercased())
            cursor += length
        case 0x04:
            guard data.count >= cursor + 16 + 2 else {
                return .incomplete
            }
            host = .ipv6(Data(data[cursor..<(cursor + 16)]))
            cursor += 16
        default:
            return .invalid
        }

        let port = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
        guard port > 0 else {
            return .invalid
        }
        cursor += 2
        return .success(
            value: Socks5Destination(host: host, port: port),
            consumed: cursor
        )
    }
}
#endif
