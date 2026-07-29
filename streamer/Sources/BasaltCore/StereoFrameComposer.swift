import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Duplicates a monoscopic desktop capture into ALVR's side-by-side stereo
/// layout. Each half contains the complete source image, preventing the client
/// from showing the left half to one eye and the right half to the other.
public final class StereoFrameComposer: @unchecked Sendable {
    public let perEyeWidth: Int
    public let height: Int
    public var outputWidth: Int { perEyeWidth * 2 }

    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let contentScale: CGFloat
    private let viewLock = NSLock()
    private var eyeCenters: [CGPoint]
    private var viewGeneration: UInt64 = 0
    private var cachedSource: CVPixelBuffer?
    private var cachedOutput: CVPixelBuffer?

    public init(sourceWidth: Int, sourceHeight: Int,
                perEyeWidth: Int, height: Int, contentScale: CGFloat = 0.9,
                convergenceShiftPixels: CGFloat = 0) throws {
        guard sourceWidth > 0, sourceHeight > 0, perEyeWidth > 0, height > 0,
              contentScale > 0, contentScale <= 1,
              convergenceShiftPixels >= 0,
              convergenceShiftPixels < CGFloat(perEyeWidth) / 4 else {
            throw BasaltError("Invalid stereo source/output dimensions or scale")
        }
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.perEyeWidth = perEyeWidth
        self.height = height
        self.contentScale = contentScale
        let shift = convergenceShiftPixels / CGFloat(perEyeWidth)
        eyeCenters = [CGPoint(x: 0.5 + shift, y: 0.5),
                      CGPoint(x: 0.5 - shift, y: 0.5)]
        context = CIContext(options: [.cacheIntermediates: false])

        let stereoWidth = perEyeWidth * 2
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: stereoWidth,
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

    /// Centers the duplicated desktop using the Quest's asymmetric eye
    /// projections. This is a static stereo calibration only; a flat captured
    /// image cannot be made world-anchored by shifting it from head poses.
    public func updateViews(_ config: AlvrViewsConfig,
                            monitorDistanceMeters: CGFloat = 1.5) {
        guard config.fov.count == 2, monitorDistanceMeters > 0 else { return }
        viewLock.lock()
        let halfIPD = CGFloat(config.ipdMeters) / 2
        var centers = [CGPoint]()
        for index in 0..<2 {
            let fov = config.fov[index]
            let tangentLeft = CGFloat(tan(Double(fov.left)))
            let tangentRight = CGFloat(tan(Double(fov.right)))
            let tangentDown = CGFloat(tan(Double(fov.down)))
            let tangentUp = CGFloat(tan(Double(fov.up)))
            let horizontalRange = tangentRight - tangentLeft
            let verticalRange = tangentUp - tangentDown
            guard horizontalRange.isFinite, horizontalRange > 0,
                  verticalRange.isFinite, verticalRange > 0 else {
                viewLock.unlock()
                return
            }

            let eyeX = index == 0 ? -halfIPD : halfIPD
            let centerRayX = -eyeX / monitorDistanceMeters
            let centerX = (centerRayX - tangentLeft) / horizontalRange
            let centerY = -tangentDown / verticalRange
            centers.append(CGPoint(x: min(max(centerX, 0.2), 0.8),
                                   y: min(max(centerY, 0.2), 0.8)))
        }
        eyeCenters = centers
        viewGeneration &+= 1
        cachedSource = nil
        cachedOutput = nil
        viewLock.unlock()
    }

    public func compose(_ sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        viewLock.lock()
        if let cachedSource, cachedSource === sourceBuffer, let cachedOutput {
            viewLock.unlock()
            return cachedOutput
        }
        let centers = eyeCenters
        let generation = viewGeneration
        viewLock.unlock()

        var maybeOutput: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeOutput) == kCVReturnSuccess,
              let output = maybeOutput else { return nil }

        let sourceBounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let source = CIImage(cvPixelBuffer: sourceBuffer).cropped(to: sourceBounds)
        let fitScale = min(CGFloat(perEyeWidth) / CGFloat(sourceWidth),
                           CGFloat(height) / CGFloat(sourceHeight))
            * contentScale
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
        let leftX = centers[0].x * CGFloat(perEyeWidth)
            - scaled.extent.width / 2 - scaled.extent.minX
        let rightX = CGFloat(perEyeWidth) + centers[1].x * CGFloat(perEyeWidth)
            - scaled.extent.width / 2 - scaled.extent.minX
        let leftY = centers[0].y * CGFloat(height)
            - scaled.extent.height / 2 - scaled.extent.minY
        let rightY = centers[1].y * CGFloat(height)
            - scaled.extent.height / 2 - scaled.extent.minY
        let left = scaled.transformed(by: CGAffineTransform(
            translationX: leftX, y: leftY))
        let right = scaled.transformed(by: CGAffineTransform(
            translationX: rightX, y: rightY))
        let outputBounds = CGRect(x: 0, y: 0, width: outputWidth, height: height)
        let background = CIImage(color: .black).cropped(to: outputBounds)
        let frame = right.composited(over: left.composited(over: background))
        context.render(frame, to: output,
                       bounds: outputBounds,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        // ScreenCaptureKit reports unchanged displays as idle. The capture
        // pacer repeats the retained source at video cadence, so reuse this
        // app-owned stereo surface instead of running Core Image again. A
        // view calibration update invalidates the cache via its generation.
        viewLock.lock()
        if generation == viewGeneration {
            cachedSource = sourceBuffer
            cachedOutput = output
        }
        viewLock.unlock()
        return output
    }
}
