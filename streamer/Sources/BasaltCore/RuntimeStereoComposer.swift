import CoreVideo
import Foundation
import Metal

/// Composes the OpenXR runtime's two per-eye images into ALVR's side-by-side
/// stereo layout. Unlike `StereoFrameComposer` (which centers a duplicated
/// desktop using IPD/FOV calibration), each game image already bakes its
/// eye's projection, so each one simply fills its half of the output.
public final class RuntimeStereoComposer: @unchecked Sendable {
    public let perEyeWidth: Int
    public let height: Int
    public var outputWidth: Int { perEyeWidth * 2 }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool

    public init(perEyeWidth: Int, height: Int) throws {
        guard perEyeWidth > 0, height > 0 else {
            throw BasaltError("Invalid stereo output dimensions")
        }
        self.perEyeWidth = perEyeWidth
        self.height = height
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw BasaltError("Metal is unavailable for runtime stereo composition")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void composeOpaqueStereo(
            texture2d<float, access::sample> left [[texture(0)]],
            texture2d<float, access::sample> right [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 position [[thread_position_in_grid]])
        {
            if (position.x >= output.get_width() ||
                position.y >= output.get_height()) {
                return;
            }
            constexpr sampler linearSampler(
                coord::normalized, address::clamp_to_edge, filter::linear);
            const uint eyeWidth = output.get_width() / 2;
            const bool rightEye = position.x >= eyeWidth;
            const uint localX = rightEye ? position.x - eyeWidth : position.x;
            const float2 uv = float2(
                (float(localX) + 0.5f) / float(eyeWidth),
                (float(position.y) + 0.5f) / float(output.get_height()));
            const float3 rgb = rightEye
                ? right.sample(linearSampler, uv).rgb
                : left.sample(linearSampler, uv).rgb;
            output.write(float4(rgb, 1.0f), position);
        }
        """
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw BasaltError("Could not compile runtime stereo compositor: \(error)")
        }
        guard let function = library.makeFunction(name: "composeOpaqueStereo") else {
            throw BasaltError("Runtime stereo compositor function is missing")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw BasaltError("Could not create runtime stereo compositor: \(error)")
        }
        self.commandQueue = commandQueue

        var maybeTextureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            nil, nil, device, nil, &maybeTextureCache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = maybeTextureCache else {
            throw BasaltError("CVMetalTextureCacheCreate failed (\(cacheStatus))")
        }
        self.textureCache = textureCache

        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: perEyeWidth * 2,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var maybePool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &maybePool)
        guard status == kCVReturnSuccess, let pool = maybePool else {
            throw BasaltError("CVPixelBufferPoolCreate failed (\(status))")
        }
        self.pool = pool
    }

    /// Scales each eye to fill its half. Source dimensions may vary per call
    /// (they follow the game's swapchain size).
    public func compose(left: CVPixelBuffer, right: CVPixelBuffer) -> CVPixelBuffer? {
        var maybeOutput: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeOutput) == kCVReturnSuccess,
              let output = maybeOutput else { return nil }

        func metalTexture(_ buffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
            var maybeTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                0, &maybeTexture)
            guard status == kCVReturnSuccess,
                  let cvTexture = maybeTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                return nil
            }
            return (cvTexture, texture)
        }

        guard let leftTexture = metalTexture(left),
              let rightTexture = metalTexture(right),
              let outputTexture = metalTexture(output),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(leftTexture.1, index: 0)
        encoder.setTexture(rightTexture.1, index: 1)
        encoder.setTexture(outputTexture.1, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: outputWidth, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return output
    }
}
