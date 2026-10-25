import Foundation

/// Bounded RFC 6455 framing for the local Codex Unix socket.
struct AgentWebSocketFrames {
    enum Frame: Equatable { case text(Data), ping(Data), closed }
    enum Failure: Error { case invalidFrame, tooLarge }
    static let limit = 8 * 1024 * 1024
    private var bytes = Data()
    private var fragment: Data?

    mutating func receive(_ data: Data) throws -> [Frame] {
        // A read can contain the end of a maximum-size frame and the beginning
        // of the next frame. The transport reads at most 64 KiB at once.
        guard bytes.count + data.count <= Self.limit + 65_536 + 14 else { throw Failure.tooLarge }
        bytes.append(data)
        var result: [Frame] = []
        while bytes.count >= 2 {
            let first = bytes[bytes.startIndex], second = bytes[bytes.startIndex + 1]
            let final = first & 0x80 != 0, opcode = first & 0x0F
            guard first & 0x70 == 0, second & 0x80 == 0 else { throw Failure.invalidFrame }
            var length = UInt64(second & 0x7F), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { break }
                length = UInt64(bytes[bytes.startIndex + 2]) << 8 | UInt64(bytes[bytes.startIndex + 3]); offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { break }
                length = bytes[(bytes.startIndex + 2)..<(bytes.startIndex + 10)].reduce(0) { ($0 << 8) | UInt64($1) }; offset = 10
            }
            guard length <= Self.limit else { throw Failure.tooLarge }
            if opcode >= 8, !final || length > 125 { throw Failure.invalidFrame }
            guard bytes.count >= offset + Int(length) else { break }
            let payload = Data(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + Int(length))])
            bytes.removeFirst(offset + Int(length))
            switch opcode {
            case 1:
                guard fragment == nil else { throw Failure.invalidFrame }
                if final { result.append(.text(payload)) } else { fragment = payload }
            case 0:
                guard var pending = fragment else { throw Failure.invalidFrame }
                guard pending.count + payload.count <= Self.limit else { throw Failure.tooLarge }
                pending.append(payload)
                if final { fragment = nil; result.append(.text(pending)) } else { fragment = pending }
            case 8: result.append(.closed)
            case 9: result.append(.ping(payload))
            case 10: break
            default: throw Failure.invalidFrame
            }
        }
        return result
    }

    static func clientFrame(_ payload: Data, opcode: UInt8 = 1) throws -> Data {
        guard payload.count <= limit else { throw Failure.tooLarge }
        var result = Data([0x80 | opcode])
        if payload.count < 126 { result.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= Int(UInt16.max) {
            result.append(0xFE); result.append(UInt8(payload.count >> 8)); result.append(UInt8(payload.count & 255))
        } else {
            result.append(0xFF)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((count >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        result.append(contentsOf: mask)
        result.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }
}
