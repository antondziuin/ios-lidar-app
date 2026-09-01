import Compression
import CoreImage
import CoreVideo
import Darwin
import Foundation
import ImageIO
import simd

enum FrameCodec {
    static let magic = Data([0x4C, 0x49, 0x44, 0x52]) // LIDR
    static let version: UInt8 = 1
    static let flagConfidence: UInt8 = 1 << 0

    static func packet(body: Data) -> Data {
        var packet = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(body)
        return packet
    }

    static func packIntrinsics(_ k: simd_float3x3) -> [Float] {
        [
            k.columns.0.x, k.columns.1.x, k.columns.2.x,
            k.columns.0.y, k.columns.1.y, k.columns.2.y,
            k.columns.0.z, k.columns.1.z, k.columns.2.z
        ]
    }

    static func packTransform(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }
}

enum DeflateCodec {
    static func compress(_ input: Data) -> Data? {
        transcode(input, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func decompress(_ input: Data) -> Data? {
        transcode(input, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transcode(_ input: Data, operation: compression_stream_operation) -> Data? {
        guard !input.isEmpty else { return Data() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        memset(stream, 0, MemoryLayout<compression_stream>.stride)

        let status = compression_stream_init(stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(stream) }

        return input.withUnsafeBytes { srcRaw -> Data? in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = src
            stream.pointee.src_size = input.count

            let chunk = 64 * 1024
            var output = Data()
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }

            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let proc = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    output.append(dst, count: produced)
                }
                if proc == COMPRESSION_STATUS_END {
                    return output
                }
                if proc == COMPRESSION_STATUS_ERROR {
                    return nil
                }
            }
        }
    }
}

final class BinaryWriter {
    private(set) var data: Data

    init(capacity: Int = 256) {
        data = Data(capacity: capacity)
    }

    func u8(_ value: UInt8) {
        data.append(value)
    }

    func u16(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    func u32(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    func f32(_ value: Float) {
        var be = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    func f64(_ value: Double) {
        var be = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    func append(_ other: Data) {
        data.append(other)
    }
}

final class FrameEncoder {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let maxRGBWidth: CGFloat = 1280
    private let jpegQuality: CGFloat = 0.6

    func encode(
        timestamp: TimeInterval,
        capturedImage: CVPixelBuffer,
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        transform: simd_float4x4
    ) -> Data? {
        guard let jpegResult = jpegData(from: capturedImage) else { return nil }
        guard let depthPlane = PixelBufferIO.copyFloat32(from: depthMap) else { return nil }
        let confidencePlane = confidenceMap.flatMap { PixelBufferIO.copyUInt8(from: $0) }

        guard let compressedDepth = DeflateCodec.compress(depthPlane.data) else { return nil }

        var flags: UInt8 = 0
        var confPayload = Data()
        if let confidencePlane {
            flags |= FrameCodec.flagConfidence
            confPayload = confidencePlane.data
        }

        var k = FrameCodec.packIntrinsics(intrinsics)
        let scale = jpegResult.scale
        k[0] *= scale
        k[2] *= scale
        k[4] *= scale
        k[5] *= scale
        let t = FrameCodec.packTransform(transform)

        let writer = BinaryWriter(
            capacity: 138 + jpegResult.data.count + compressedDepth.count + confPayload.count
        )
        writer.append(FrameCodec.magic)
        writer.u8(FrameCodec.version)
        writer.u8(flags)
        writer.f64(timestamp)
        writer.u16(UInt16(jpegResult.width))
        writer.u16(UInt16(jpegResult.height))
        writer.u16(UInt16(depthPlane.width))
        writer.u16(UInt16(depthPlane.height))
        writer.u32(UInt32(jpegResult.data.count))
        writer.u32(UInt32(compressedDepth.count))
        writer.u32(UInt32(confPayload.count))
        writer.u32(0)
        for value in k { writer.f32(value) }
        for value in t { writer.f32(value) }
        writer.append(jpegResult.data)
        writer.append(compressedDepth)
        writer.append(confPayload)
        return writer.data
    }

    private struct JPEGResult {
        let data: Data
        let width: Int
        let height: Int
        let scale: Float
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> JPEGResult? {
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
        let originalHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let scale = min(1.0, maxRGBWidth / CGFloat(originalWidth))
        let outW = max(1, Int((CGFloat(originalWidth) * scale).rounded(.towardZero)))
        let outH = max(1, Int((CGFloat(originalHeight) * scale).rounded(.towardZero)))

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        if extent.width > 0, extent.height > 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            let sx = CGFloat(outW) / extent.width
            let sy = CGFloat(outH) / extent.height
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [qualityKey: jpegQuality]
        ) else {
            return nil
        }
        return JPEGResult(
            data: data,
            width: outW,
            height: outH,
            scale: Float(outW) / Float(originalWidth)
        )
    }
}

enum PixelBufferIO {
    struct Plane {
        let data: Data
        let width: Int
        let height: Int
    }

    static func copyFloat32(from pixelBuffer: CVPixelBuffer) -> Plane? {
        copyTight(from: pixelBuffer, bytesPerPixel: 4)
    }

    static func copyUInt8(from pixelBuffer: CVPixelBuffer) -> Plane? {
        copyTight(from: pixelBuffer, bytesPerPixel: 1)
    }

    private static func copyTight(from pixelBuffer: CVPixelBuffer, bytesPerPixel: Int) -> Plane? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let rowBytes = width * bytesPerPixel
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { dest in
            guard let dst = dest.baseAddress else { return }
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow)
                memcpy(dst.advanced(by: row * rowBytes), src, rowBytes)
            }
        }
        return Plane(data: data, width: width, height: height)
    }
}
