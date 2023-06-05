import Foundation
import AVFoundation
import UIKit
import CoreImage
import Metal
import MetalKit
import Display
import SwiftSignalKit
import TelegramCore
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import YuvConversion
import StickerResources

public func mediaEditorGenerateGradientImage(size: CGSize, colors: [UIColor]) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
    if let context = UIGraphicsGetCurrentContext() {
        let gradientColors = colors.map { $0.cgColor } as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        var locations: [CGFloat] = [0.0, 1.0]
        let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
    }
    
    let image = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    
    return image
}

public func mediaEditorGetGradientColors(from image: UIImage) -> (UIColor, UIColor) {
    let context = DrawingContext(size: CGSize(width: 5.0, height: 5.0), scale: 1.0, clear: false)!
    context.withFlippedContext({ context in
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(x: 0.0, y: 0.0, width: 5.0, height: 5.0))
        }
    })
    return (context.colorAt(CGPoint(x: 2.0, y: 0.0)), context.colorAt(CGPoint(x: 2.0, y: 4.0)))
}

final class MediaEditorComposer {
    let device: MTLDevice?
    private let colorSpace: CGColorSpace
    
    private let values: MediaEditorValues
    private let dimensions: CGSize
    private let outputDimensions: CGSize
    
    private let ciContext: CIContext?
    private var textureCache: CVMetalTextureCache?
    
    private let renderer = MediaEditorRenderer()
    private let renderChain = MediaEditorRenderChain()
    
    private let gradientImage: CIImage
    private let drawingImage: CIImage?
    private var entities: [MediaEditorComposerEntity]
    
    init(account: Account, values: MediaEditorValues, dimensions: CGSize, outputDimensions: CGSize) {
        self.values = values
        self.dimensions = dimensions
        self.outputDimensions = outputDimensions
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        self.colorSpace = colorSpace
        
        self.renderer.addRenderChain(self.renderChain)
        
        if let gradientColors = values.gradientColors, let image = mediaEditorGenerateGradientImage(size: dimensions, colors: gradientColors) {
            self.gradientImage = CIImage(image: image, options: [.colorSpace: self.colorSpace])!.transformed(by: CGAffineTransform(translationX: -dimensions.width / 2.0, y: -dimensions.height / 2.0))
        } else {
            self.gradientImage = CIImage(color: .black)
        }
        
        if let drawing = values.drawing, let drawingImage = CIImage(image: drawing, options: [.colorSpace: self.colorSpace]) {
            self.drawingImage = drawingImage.transformed(by: CGAffineTransform(translationX: -dimensions.width / 2.0, y: -dimensions.height / 2.0))
        } else {
            self.drawingImage = nil
        }
        
        self.entities = values.entities.map { $0.entity } .compactMap { composerEntityForDrawingEntity(account: account, entity: $0, colorSpace: colorSpace) }
        
        self.device = MTLCreateSystemDefaultDevice()
        if let device = self.device {
            self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace : self.colorSpace])
            
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &self.textureCache)
        } else {
            self.ciContext = nil
        }
                
        self.renderer.setupForComposer(composer: self)
        self.renderChain.update(values: self.values)
    }
    
    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, pool: CVPixelBufferPool?, textureRotation: TextureRotation, completion: @escaping (CVPixelBuffer?) -> Void) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let pool = pool else {
            completion(nil)
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        self.renderer.consumeVideoPixelBuffer(imageBuffer, rotation: textureRotation, timestamp: time, render: true)
        
        if let finalTexture = self.renderer.finalTexture, var ciImage = CIImage(mtlTexture: finalTexture, options: [.colorSpace: self.colorSpace]) {
            ciImage = ciImage.transformed(by: CGAffineTransformMakeScale(1.0, -1.0).translatedBy(x: 0.0, y: -ciImage.extent.height))
            
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            
            if let pixelBuffer {
                processImage(inputImage: ciImage, time: time, completion: { compositedImage in
                    if var compositedImage {
                        let scale = self.outputDimensions.width / self.dimensions.width
                        compositedImage = compositedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
 
                        self.ciContext?.render(compositedImage, to: pixelBuffer)
                        completion(pixelBuffer)
                    } else {
                        completion(nil)
                    }
                })
                return
            }
        }
        completion(nil)
    }
    
    private var filteredImage: CIImage?
    func processImage(inputImage: UIImage, pool: CVPixelBufferPool?, time: CMTime, completion: @escaping (CVPixelBuffer?, CMTime) -> Void) {
        guard let pool else {
            completion(nil, time)
            return
        }
        if self.filteredImage == nil, let device = self.device {
            if let texture = loadTexture(image: inputImage, device: device) {
                self.renderer.consumeTexture(texture, render: true)
                
                if let finalTexture = self.renderer.finalTexture, var ciImage = CIImage(mtlTexture: finalTexture, options: [.colorSpace: self.colorSpace]) {
                    ciImage = ciImage.transformed(by: CGAffineTransformMakeScale(1.0, -1.0).translatedBy(x: 0.0, y: -ciImage.extent.height))
                    self.filteredImage = ciImage
                }
            }
        }
        
        if let image = self.filteredImage {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            
            if let pixelBuffer {
                makeEditorImageFrameComposition(inputImage: image, gradientImage: self.gradientImage, drawingImage: self.drawingImage, dimensions: self.dimensions, values: self.values, entities: self.entities, time: time, completion: { compositedImage in
                    if var compositedImage {
                        let scale = self.outputDimensions.width / self.dimensions.width
                        compositedImage = compositedImage.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        
                        self.ciContext?.render(compositedImage, to: pixelBuffer)
                        completion(pixelBuffer, time)
                    } else {
                        completion(nil, time)
                    }
                })
                return
            }
        }
        completion(nil, time)
    }
    
    func processImage(inputImage: CIImage, time: CMTime, completion: @escaping (CIImage?) -> Void) {
        makeEditorImageFrameComposition(inputImage: inputImage, gradientImage: self.gradientImage, drawingImage: self.drawingImage, dimensions: self.dimensions, values: self.values, entities: self.entities, time: time, completion: completion)
    }
}

public func makeEditorImageComposition(account: Account, inputImage: UIImage, dimensions: CGSize, values: MediaEditorValues, time: CMTime, completion: @escaping (UIImage?) -> Void) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let inputImage = CIImage(image: inputImage, options: [.colorSpace: colorSpace])!
    let gradientImage: CIImage
    var drawingImage: CIImage?
    if let gradientColors = values.gradientColors, let image = mediaEditorGenerateGradientImage(size: dimensions, colors: gradientColors) {
        gradientImage = CIImage(image: image, options: [.colorSpace: colorSpace])!.transformed(by: CGAffineTransform(translationX: -dimensions.width / 2.0, y: -dimensions.height / 2.0))
    } else {
        gradientImage = CIImage(color: .black)
    }
    
    if let drawing = values.drawing, let image = CIImage(image: drawing, options: [.colorSpace: colorSpace]) {
        drawingImage = image.transformed(by: CGAffineTransform(translationX: -dimensions.width / 2.0, y: -dimensions.height / 2.0))
    }
    
    let entities: [MediaEditorComposerEntity] = values.entities.map { $0.entity }.compactMap { composerEntityForDrawingEntity(account: account, entity: $0, colorSpace: colorSpace) }
    makeEditorImageFrameComposition(inputImage: inputImage, gradientImage: gradientImage, drawingImage: drawingImage, dimensions: dimensions, values: values, entities: entities, time: time, completion: { ciImage in
        if let ciImage {
            let context = CIContext(options: [.workingColorSpace : NSNull()])
            if let cgImage = context.createCGImage(ciImage, from: CGRect(origin: .zero, size: ciImage.extent.size)) {
                Queue.mainQueue().async {
                    completion(UIImage(cgImage: cgImage))
                }
                return
            }
        }
        completion(nil)
    })
}

private func makeEditorImageFrameComposition(inputImage: CIImage, gradientImage: CIImage, drawingImage: CIImage?, dimensions: CGSize, values: MediaEditorValues, entities: [MediaEditorComposerEntity], time: CMTime, completion: @escaping (CIImage?) -> Void) {
    var resultImage = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: dimensions)).transformed(by: CGAffineTransform(translationX: -dimensions.width / 2.0, y: -dimensions.height / 2.0))
    resultImage = gradientImage.composited(over: resultImage)
    
    var mediaImage = inputImage.samplingLinear().transformed(by: CGAffineTransform(translationX: -inputImage.extent.midX, y: -inputImage.extent.midY))
    
    var initialScale: CGFloat
    if mediaImage.extent.height > mediaImage.extent.width {
        initialScale = max(dimensions.width / mediaImage.extent.width, dimensions.height / mediaImage.extent.height)
    } else {
        initialScale = dimensions.width / mediaImage.extent.width
    }
    
    var cropTransform = CGAffineTransform(translationX: values.cropOffset.x, y: values.cropOffset.y * -1.0)
    cropTransform = cropTransform.rotated(by: -values.cropRotation)
    cropTransform = cropTransform.scaledBy(x: initialScale * values.cropScale, y: initialScale * values.cropScale)
    mediaImage = mediaImage.transformed(by: cropTransform)
    resultImage = mediaImage.composited(over: resultImage)
    
    if let drawingImage {
        resultImage = drawingImage.samplingLinear().composited(over: resultImage)
    }
    
    let frameRate: Float = 30.0
    
    let entitiesCount = Atomic<Int>(value: 1)
    let entitiesImages = Atomic<[(CIImage, Int)]>(value: [])
    let maybeFinalize = {
        let count = entitiesCount.modify { current -> Int in
            return current - 1
        }
        if count == 0 {
            let sortedImages = entitiesImages.with({ $0 }).sorted(by: { $0.1 < $1.1 }).map({ $0.0 })
            for image in sortedImages {
                resultImage = image.composited(over: resultImage)
            }
            
            resultImage = resultImage.transformed(by: CGAffineTransform(translationX: dimensions.width / 2.0, y: dimensions.height / 2.0))
            resultImage = resultImage.cropped(to: CGRect(origin: .zero, size: dimensions))
            completion(resultImage)
        }
    }
    var i = 0
    for entity in entities {
        let _ = entitiesCount.modify { current -> Int in
            return current + 1
        }
        let index = i
        entity.image(for: time, frameRate: frameRate, completion: { image in
            if var image = image?.samplingLinear() {
                let resetTransform = CGAffineTransform(translationX: -image.extent.width / 2.0, y: -image.extent.height / 2.0)
                image = image.transformed(by: resetTransform)
                
                var baseScale: CGFloat = 1.0
                if let baseSize = entity.baseSize {
                    baseScale = baseSize.width / image.extent.width
                }
                
                var transform = CGAffineTransform.identity
                transform = transform.translatedBy(x: -dimensions.width / 2.0 + entity.position.x, y: dimensions.height / 2.0 + entity.position.y * -1.0)
                transform = transform.rotated(by: -entity.rotation)
                transform = transform.scaledBy(x: entity.scale * baseScale, y: entity.scale * baseScale)
                if entity.mirrored {
                    transform = transform.scaledBy(x: -1.0, y: 1.0)
                }
                                                            
                image = image.transformed(by: transform)
                let _ = entitiesImages.modify { current in
                    var updated = current
                    updated.append((image, index))
                    return updated
                }
            }
            maybeFinalize()
        })
        i += 1
    }
    maybeFinalize()
}

private func composerEntityForDrawingEntity(account: Account, entity: DrawingEntity, colorSpace: CGColorSpace) -> MediaEditorComposerEntity? {
    if let entity = entity as? DrawingStickerEntity {
        let content: MediaEditorComposerStickerEntity.Content
        switch entity.content {
        case let .file(file):
            content = .file(file)
        case let .image(image):
            content = .image(image)
        }
        return MediaEditorComposerStickerEntity(account: account, content: content, position: entity.position, scale: entity.scale, rotation: entity.rotation, baseSize: entity.baseSize, mirrored: entity.mirrored, colorSpace: colorSpace)
    } else if let renderImage = entity.renderImage, let image = CIImage(image: renderImage, options: [.colorSpace: colorSpace]) {
        if let entity = entity as? DrawingBubbleEntity {
            return MediaEditorComposerStaticEntity(image: image, position: entity.position, scale: 1.0, rotation: entity.rotation, baseSize: entity.size, mirrored: false)
        } else if let entity = entity as? DrawingSimpleShapeEntity {
            return MediaEditorComposerStaticEntity(image: image, position: entity.position, scale: 1.0, rotation: entity.rotation, baseSize: entity.size, mirrored: false)
        } else if let entity = entity as? DrawingVectorEntity {
            return MediaEditorComposerStaticEntity(image: image, position: CGPoint(x: entity.drawingSize.width * 0.5, y: entity.drawingSize.height * 0.5), scale: 1.0, rotation: 0.0, baseSize: entity.drawingSize, mirrored: false)
        } else if let entity = entity as? DrawingTextEntity {
            return MediaEditorComposerStaticEntity(image: image, position: entity.position, scale: entity.scale, rotation: entity.rotation, baseSize: nil, mirrored: false)
        }
    }
    return nil
}

private class MediaEditorComposerStaticEntity: MediaEditorComposerEntity {
    let image: CIImage
    let position: CGPoint
    let scale: CGFloat
    let rotation: CGFloat
    let baseSize: CGSize?
    let mirrored: Bool
    
    init(image: CIImage, position: CGPoint, scale: CGFloat, rotation: CGFloat, baseSize: CGSize?, mirrored: Bool) {
        self.image = image
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.baseSize = baseSize
        self.mirrored = mirrored
    }
    
    func image(for time: CMTime, frameRate: Float, completion: @escaping (CIImage?) -> Void) {
        completion(self.image)
    }
}

private class MediaEditorComposerStickerEntity: MediaEditorComposerEntity {
    public enum Content {
        case file(TelegramMediaFile)
        case image(UIImage)
        
        var file: TelegramMediaFile? {
            if case let .file(file) = self {
                return file
            }
            return nil
        }
    }
    
    let content: Content
    let position: CGPoint
    let scale: CGFloat
    let rotation: CGFloat
    let baseSize: CGSize?
    let mirrored: Bool
    let colorSpace: CGColorSpace
    
    var isAnimated: Bool
    var source: AnimatedStickerNodeSource?
    var frameSource = Promise<QueueLocalObject<AnimatedStickerDirectFrameSource>?>()
    
    var frameCount: Int?
    var frameRate: Int?
    var currentFrameIndex: Int?
    var totalDuration: Double?
    let durationPromise = Promise<Double>()
    
    let queue = Queue()
    let disposables = DisposableSet()
    
    var image: CIImage?
    var imagePixelBuffer: CVPixelBuffer?
    let imagePromise = Promise<UIImage>()
    
    init(account: Account, content: Content, position: CGPoint, scale: CGFloat, rotation: CGFloat, baseSize: CGSize, mirrored: Bool, colorSpace: CGColorSpace) {
        self.content = content
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.baseSize = baseSize
        self.mirrored = mirrored
        self.colorSpace = colorSpace
        
        switch content {
        case let .file(file):
            if file.isAnimatedSticker || file.isVideoSticker || file.mimeType == "video/webm" {
                self.isAnimated = true
                self.source = AnimatedStickerResourceSource(account: account, resource: file.resource, isVideo: file.isVideoSticker || file.mimeType == "video/webm")
                let pathPrefix = account.postbox.mediaBox.shortLivedResourceCachePathPrefix(file.resource.id)
                if let source = self.source {
                    let dimensions = file.dimensions ?? PixelDimensions(width: 512, height: 512)
                    let fittedDimensions = dimensions.cgSize.aspectFitted(CGSize(width: 384, height: 384))
                    self.disposables.add((source.directDataPath(attemptSynchronously: true)
                    |> deliverOn(self.queue)).start(next: { [weak self] path in
                        if let strongSelf = self, let path {
                            if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedRead]) {
                                let queue = strongSelf.queue
                                let frameSource = QueueLocalObject<AnimatedStickerDirectFrameSource>(queue: queue, generate: {
                                    return AnimatedStickerDirectFrameSource(queue: queue, data: data, width: Int(fittedDimensions.width), height: Int(fittedDimensions.height), cachePathPrefix: pathPrefix, useMetalCache: false, fitzModifier: nil)!
                                })
                                frameSource.syncWith { frameSource in
                                    strongSelf.frameCount = frameSource.frameCount
                                    strongSelf.frameRate = frameSource.frameRate
                                    
                                    let duration = Double(frameSource.frameCount) / Double(frameSource.frameRate)
                                    strongSelf.totalDuration = duration
                                    strongSelf.durationPromise.set(.single(duration))
                                }
                                                             
                                strongSelf.frameSource.set(.single(frameSource))
                            }
                        }
                    }))
                }
            } else {
                self.isAnimated = false
                self.disposables.add((chatMessageSticker(account: account, userLocation: .other, file: file, small: false, fetched: true, onlyFullSize: true, thumbnail: false, synchronousLoad: false, colorSpace: self.colorSpace)
                |> deliverOn(self.queue)).start(next: { [weak self] generator in
                    if let self {
                        let context = generator(TransformImageArguments(corners: ImageCorners(), imageSize: baseSize, boundingSize: baseSize, intrinsicInsets: UIEdgeInsets()))
                        let image = context?.generateImage(colorSpace: self.colorSpace)
                        if let image {
                            self.imagePromise.set(.single(image))
                        }
                    }
                }))
            }
        case let .image(image):
            self.isAnimated = false
            self.imagePromise.set(.single(image))
        }
    }
    
    deinit {
        self.disposables.dispose()
    }
    
    var tested = false
    func image(for time: CMTime, frameRate: Float, completion: @escaping (CIImage?) -> Void) {
        if self.isAnimated {
            let currentTime = CMTimeGetSeconds(time)
            
            var tintColor: UIColor?
            if let file = self.content.file, file.isCustomTemplateEmoji {
                tintColor = .white
            }
            
            self.disposables.add((self.frameSource.get()
            |> take(1)
            |> deliverOn(self.queue)).start(next: { [weak self] frameSource in
                guard let strongSelf = self else {
                    completion(nil)
                    return
                }
                
                guard let frameSource, let duration = strongSelf.totalDuration, let frameCount = strongSelf.frameCount else {
                    completion(nil)
                    return
                }
                                                
                let relativeTime = currentTime - floor(currentTime / duration) * duration
                var t = relativeTime / duration
                t = max(0.0, t)
                t = min(1.0, t)
                
                let startFrame: Double = 0
                let endFrame = Double(frameCount)
                
                let frameOffset = Int(Double(startFrame) * (1.0 - t) + Double(endFrame - 1) * t)
                let lowerBound: Int = 0
                let upperBound = frameCount - 1
                let frameIndex = max(lowerBound, min(upperBound, frameOffset))
                
                let currentFrameIndex = strongSelf.currentFrameIndex
                if currentFrameIndex != frameIndex {
                    let previousFrameIndex = currentFrameIndex
                    strongSelf.currentFrameIndex = frameIndex
                    
                    var delta = 1
                    if let previousFrameIndex = previousFrameIndex {
                        delta = max(1, frameIndex - previousFrameIndex)
                    }
                    
                    var frame: AnimatedStickerFrame?
                    frameSource.syncWith { frameSource in
                        for i in 0 ..< delta {
                            frame = frameSource.takeFrame(draw: i == delta - 1)
                        }
                    }
                    if let frame {
                        var imagePixelBuffer: CVPixelBuffer?
                        if let pixelBuffer = strongSelf.imagePixelBuffer {
                            imagePixelBuffer = pixelBuffer
                        } else {
                            let ioSurfaceProperties = NSMutableDictionary()
                            let options = NSMutableDictionary()
                            options.setObject(ioSurfaceProperties, forKey: kCVPixelBufferIOSurfacePropertiesKey as NSString)
                            
                            var pixelBuffer: CVPixelBuffer?
                            CVPixelBufferCreate(
                                kCFAllocatorDefault,
                                frame.width,
                                frame.height,
                                kCVPixelFormatType_32BGRA,
                                options,
                                &pixelBuffer
                            )
                            
                            imagePixelBuffer = pixelBuffer
                            strongSelf.imagePixelBuffer = pixelBuffer
                        }
                        
                        if let imagePixelBuffer {
                            let image = render(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: frame.data, type: frame.type, pixelBuffer: imagePixelBuffer, colorSpace: strongSelf.colorSpace, tintColor: tintColor)
                            strongSelf.image = image
                        }
                        completion(strongSelf.image)
                    } else {
                        completion(nil)
                    }
                } else {
                    completion(strongSelf.image)
                }
            }))
        } else {
            var image: CIImage?
            if let cachedImage = self.image {
                image = cachedImage
                completion(image)
            } else {
                let _ = (self.imagePromise.get()
                |> take(1)
                |> deliverOn(self.queue)).start(next: { [weak self] image in
                    if let self {
                        self.image = CIImage(image: image, options: [.colorSpace: self.colorSpace])
                        completion(self.image)
                    }
                })
            }
        }
    }
}

protocol MediaEditorComposerEntity {
    var position: CGPoint { get }
    var scale: CGFloat { get }
    var rotation: CGFloat { get }
    var baseSize: CGSize? { get }
    var mirrored: Bool { get }
    
    func image(for time: CMTime, frameRate: Float, completion: @escaping (CIImage?) -> Void)
}

private func render(width: Int, height: Int, bytesPerRow: Int, data: Data, type: AnimationRendererFrameType, pixelBuffer: CVPixelBuffer, colorSpace: CGColorSpace, tintColor: UIColor?) -> CIImage? {
    //let calculatedBytesPerRow = (4 * Int(width) + 31) & (~31)
    //assert(bytesPerRow == calculatedBytesPerRow)
    
    
    CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
    let dest = CVPixelBufferGetBaseAddress(pixelBuffer)
    
    switch type {
        case .yuva:
            data.withUnsafeBytes { buffer -> Void in
                guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                decodeYUVAToRGBA(bytes, dest, Int32(width), Int32(height), Int32(width * 4))
            }
        case .argb:
            data.withUnsafeBytes { buffer -> Void in
                guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                memcpy(dest, bytes, data.count)
            }
        case .dct:
            break
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
    
    return CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: colorSpace])
}
