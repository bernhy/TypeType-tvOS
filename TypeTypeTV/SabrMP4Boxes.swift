import Foundation

/// Minimal top-level ISO BMFF box validation for the existing AVAssetReader
/// path. This does not attempt to demux a codec or replace VideoToolbox.
enum SabrMP4Boxes {
    static func types(in bytes: Data) throws -> Set<String> {
        var offset = 0
        var types = Set<String>()
        let length = bytes.count

        func integer(at offset: Int, count: Int) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<count {
                result = (result << 8) | UInt64(bytes[bytes.startIndex + offset + i])
            }
            return result
        }

        while offset < length {
            let remaining = length - offset
            guard remaining >= 8 else {
                throw SabrFailure.invalidResponse("truncated MP4 box header")
            }
            let size32 = integer(at: offset, count: 4)
            let rawType = (0..<4).map { bytes[bytes.startIndex + offset + 4 + $0] }
            guard let type = String(bytes: rawType, encoding: .ascii) else {
                throw SabrFailure.invalidResponse("invalid MP4 box identifier")
            }
            var headerSize = 8
            var size = size32
            if size32 == 1 {
                guard remaining >= 16 else {
                    throw SabrFailure.invalidResponse("truncated extended MP4 box header")
                }
                headerSize = 16
                size = integer(at: offset + 8, count: 8)
            } else if size32 == 0 {
                // ISO BMFF: a zero-size top-level box extends to EOF.
                size = UInt64(remaining)
            }
            guard size >= UInt64(headerSize), size <= UInt64(remaining) else {
                throw SabrFailure.invalidResponse("invalid MP4 box length (\(type))")
            }
            types.insert(type)
            offset += Int(size)
        }
        return types
    }

    static func validate(initialization: Data, fragment: Data) throws {
        let initBoxes = try types(in: initialization)
        let mediaBoxes = try types(in: fragment)
        guard initBoxes.contains("moov"), mediaBoxes.contains("moof"),
              mediaBoxes.contains("mdat") else {
            throw SabrFailure.unsupported(
                "SABR segment is not a complete fragmented MP4 init/media pair"
            )
        }
    }
}
