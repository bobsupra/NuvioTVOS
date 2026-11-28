import CoreGraphics
import CoreML
import Foundation

struct SceneCoreMLDetectedFace: Sendable {
    /// Normalized rectangle in Vision coordinates, with a bottom-left origin.
    let boundingBox: CGRect
    /// YuNet's right eye, left eye, nose, right mouth, left mouth, in top-left pixel coordinates.
    let landmarks: [CGPoint]
    let confidence: Float
}

enum SceneCoreMLFacePipelineError: LocalizedError {
    case missingModel(String)
    case invalidModelFeature(model: String, feature: String, expected: String, actual: String)
    case invalidImage
    case invalidLandmarks
    case noFaceDetected
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .missingModel(let name):
            return "Missing compiled scene model \(name).mlmodelc."
        case .invalidModelFeature(let model, let feature, let expected, let actual):
            return "\(model) feature \(feature) expected \(expected), got \(actual)."
        case .invalidImage:
            return "Unable to prepare the image for scene face inference."
        case .invalidLandmarks:
            return "SFace alignment requires five finite landmarks."
        case .noFaceDetected:
            return "YuNet did not detect a face in the supplied image."
        case .invalidEmbedding:
            return "SFace returned an invalid or zero-length embedding."
        }
    }
}

/// CPU Core ML face detection and embedding pipeline. Model inference runs on this actor.
actor SceneCoreMLFacePipeline: FaceEmbeddingModelProtocol {
    nonisolated let modelVersion = "yunet-sface-f32-v1"
    nonisolated let inputDimension = CGSize(width: 112, height: 112)
    nonisolated let acceptanceDistance: Float = 0.64
    nonisolated let marginDistance: Float = 0.12

    private let yuNetModel: MLModel
    private let sFaceModel: MLModel

    private static let inputSize = 640
    private static let confidenceThreshold: Float = 0.6
    private static let nmsIoUThreshold: CGFloat = 0.3
    private static let sFaceLandmarkTargets: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]
    private static let yuNetHeads: [YuNetHead] = [
        YuNetHead(stride: 8, columns: 80, rows: 80, classification: "var_762", objectness: "var_813", box: "var_863", landmarks: "var_911"),
        YuNetHead(stride: 16, columns: 40, rows: 40, classification: "var_779", objectness: "var_830", box: "var_879", landmarks: "var_927"),
        YuNetHead(stride: 32, columns: 20, rows: 20, classification: "var_796", objectness: "var_847", box: "var_895", landmarks: "var_943")
    ]

    init(bundle: Bundle = .main) throws {
        let configuration = MLModelConfiguration()
        // On tvOS devices, GPU/ANE execution paths attempt to compile or cache MPSGraph
        // compute packages in tmp using POSIX link(), which is rejected by the tvOS app
        // sandbox policy and causes MPSGraphComputePackage.mm to abort with a failed assertion.
        // YuNet and SFace are small models that run in ~15-25ms on CPU without GPU contention.
        configuration.computeUnits = .cpuOnly

        let removedBytes = SceneModelCacheCleanup.removeCopiesFromEarlierInstalls()
        if removedBytes > 0 {
            print("[ActorRecognition] Removed \(removedBytes / 1_000_000) MB of compiled models from earlier installs")
        }
        let yuNet = try Self.loadModel(named: "YuNet", from: bundle, configuration: configuration)
        let sFace = try Self.loadModel(named: "SFace", from: bundle, configuration: configuration)
        try Self.validateYuNet(yuNet)
        try Self.validateSFace(sFace)
        self.yuNetModel = yuNet
        self.sFaceModel = sFace
    }

    /// Detects faces and returns Vision-style boxes with top-left pixel landmarks.
    func detectFaces(in image: CGImage) async throws -> [SceneCoreMLDetectedFace] {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw SceneCoreMLFacePipelineError.invalidImage
        }

        let size = Self.inputSize
        let fitScale = min(CGFloat(size) / CGFloat(sourceWidth), CGFloat(size) / CGFloat(sourceHeight))
        let resizedWidth = max(1, min(size, Int((CGFloat(sourceWidth) * fitScale).rounded())))
        let resizedHeight = max(1, min(size, Int((CGFloat(sourceHeight) * fitScale).rounded())))
        let scaleX = CGFloat(resizedWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(resizedHeight) / CGFloat(sourceHeight)
        let inputPixels = try Self.drawRGBA(
            image,
            canvasWidth: size,
            canvasHeight: size,
            destinationRect: CGRect(x: 0, y: size - resizedHeight, width: resizedWidth, height: resizedHeight)
        )

        let input = try Self.makeMultiArray(shape: [1, 3, size, size])
        let planeSize = size * size
        let tensor = input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)
        for y in 0..<size {
            let pixelRow = y * size
            let tensorRow = y * size
            for x in 0..<size {
                let pixelIndex = (pixelRow + x) * 4
                let tensorIndex = tensorRow + x
                tensor[tensorIndex] = Float32(inputPixels[pixelIndex + 2])
                tensor[planeSize + tensorIndex] = Float32(inputPixels[pixelIndex + 1])
                tensor[(2 * planeSize) + tensorIndex] = Float32(inputPixels[pixelIndex])
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["frame_input": input])
        let prediction = try await yuNetModel.prediction(from: provider)
        var proposals: [FaceProposal] = []

        for head in Self.yuNetHeads {
            let classifications = try Self.outputArray(head.classification, from: prediction)
            let objectness = try Self.outputArray(head.objectness, from: prediction)
            let boxes = try Self.outputArray(head.box, from: prediction)
            let landmarks = try Self.outputArray(head.landmarks, from: prediction)
            let classificationValues = classifications.dataPointer.bindMemory(to: Float32.self, capacity: classifications.count)
            let objectnessValues = objectness.dataPointer.bindMemory(to: Float32.self, capacity: objectness.count)
            let boxValues = boxes.dataPointer.bindMemory(to: Float32.self, capacity: boxes.count)
            let landmarkValues = landmarks.dataPointer.bindMemory(to: Float32.self, capacity: landmarks.count)
            let classificationStrides = classifications.strides.map(\.intValue)
            let objectnessStrides = objectness.strides.map(\.intValue)
            let boxStrides = boxes.strides.map(\.intValue)
            let landmarkStrides = landmarks.strides.map(\.intValue)

            for row in 0..<head.rows {
                for column in 0..<head.columns {
                    let index = row * head.columns + column
                    let classification = Self.clampedProbability(classificationValues[index * classificationStrides[1]])
                    let objectnessScore = Self.clampedProbability(objectnessValues[index * objectnessStrides[1]])
                    let score = sqrt(classification * objectnessScore)
                    guard score >= Self.confidenceThreshold else { continue }

                    let boxOffset = index * boxStrides[1]
                    let centerX = (Float(column) + boxValues[boxOffset]) * Float(head.stride)
                    let centerY = (Float(row) + boxValues[boxOffset + boxStrides[2]]) * Float(head.stride)
                    let boxWidth = exp(boxValues[boxOffset + 2 * boxStrides[2]]) * Float(head.stride)
                    let boxHeight = exp(boxValues[boxOffset + 3 * boxStrides[2]]) * Float(head.stride)
                    guard centerX.isFinite, centerY.isFinite, boxWidth.isFinite, boxHeight.isFinite,
                          boxWidth > 0, boxHeight > 0 else {
                        continue
                    }

                    let canvasRect = CGRect(
                        x: CGFloat(centerX - boxWidth / 2),
                        y: CGFloat(centerY - boxHeight / 2),
                        width: CGFloat(boxWidth),
                        height: CGFloat(boxHeight)
                    )
                    let sourceRect = CGRect(
                        x: canvasRect.minX / scaleX,
                        y: canvasRect.minY / scaleY,
                        width: canvasRect.width / scaleX,
                        height: canvasRect.height / scaleY
                    ).intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
                    guard !sourceRect.isNull, !sourceRect.isEmpty else { continue }

                    var sourceLandmarks: [CGPoint] = []
                    sourceLandmarks.reserveCapacity(5)
                    let landmarkOffset = index * landmarkStrides[1]
                    for landmarkIndex in 0..<5 {
                        let xOffset = landmarkOffset + landmarkIndex * 2 * landmarkStrides[2]
                        let yOffset = xOffset + landmarkStrides[2]
                        let x = (Float(column) + landmarkValues[xOffset]) * Float(head.stride)
                        let y = (Float(row) + landmarkValues[yOffset]) * Float(head.stride)
                        guard x.isFinite, y.isFinite else {
                            sourceLandmarks.removeAll()
                            break
                        }
                        sourceLandmarks.append(CGPoint(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY))
                    }
                    guard sourceLandmarks.count == 5 else { continue }

                    let normalizedBox = CGRect(
                        x: sourceRect.minX / CGFloat(sourceWidth),
                        y: 1 - (sourceRect.maxY / CGFloat(sourceHeight)),
                        width: sourceRect.width / CGFloat(sourceWidth),
                        height: sourceRect.height / CGFloat(sourceHeight)
                    )
                    proposals.append(FaceProposal(
                        boundingBox: normalizedBox,
                        landmarks: sourceLandmarks,
                        confidence: score
                    ))
                }
            }
        }

        return Self.nonMaximumSuppression(proposals, threshold: Self.nmsIoUThreshold).map {
            SceneCoreMLDetectedFace(boundingBox: $0.boundingBox, landmarks: $0.landmarks, confidence: $0.confidence)
        }
    }

    /// Aligns a face using YuNet's five-point landmark order and returns an L2-normalized SFace vector.
    func embedding(for image: CGImage, landmarks: [CGPoint]) async throws -> [Float] {
        guard landmarks.count == 5, landmarks.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw SceneCoreMLFacePipelineError.invalidLandmarks
        }

        let sourcePixels = try Self.drawRGBA(
            image,
            canvasWidth: image.width,
            canvasHeight: image.height,
            destinationRect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let transform = try Self.similarityTransform(source: landmarks, destination: Self.sFaceLandmarkTargets)
        let size = Int(inputDimension.width)
        let input = try Self.makeMultiArray(shape: [1, 3, size, size])
        let planeSize = size * size
        let tensor = input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)

        for y in 0..<size {
            for x in 0..<size {
                let sourcePoint = transform.inverseMap(x: CGFloat(x), y: CGFloat(y))
                let (red, green, blue) = Self.sampleBilinear(
                    sourcePixels,
                    width: image.width,
                    height: image.height,
                    x: sourcePoint.x,
                    y: sourcePoint.y
                )
                let index = y * size + x
                tensor[index] = Float32(red)
                tensor[planeSize + index] = Float32(green)
                tensor[(2 * planeSize) + index] = Float32(blue)
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["face_input": input])
        let prediction = try await sFaceModel.prediction(from: provider)
        let output = try Self.outputArray("var_811", from: prediction)
        guard output.count == 128 else {
            throw SceneCoreMLFacePipelineError.invalidModelFeature(
                model: "SFace",
                feature: "var_811",
                expected: "128 float values",
                actual: "\(output.count) values"
            )
        }

        let outputValues = output.dataPointer.bindMemory(to: Float32.self, capacity: output.count)
        let outputStrides = output.strides.map(\.intValue)
        var result = (0..<output.count).map { Float(outputValues[$0 * outputStrides[1]]) }
        guard result.allSatisfy(\.isFinite) else { throw SceneCoreMLFacePipelineError.invalidEmbedding }
        let norm = sqrt(result.reduce(Float.zero) { $0 + ($1 * $1) })
        guard norm.isFinite, norm > 1e-12 else { throw SceneCoreMLFacePipelineError.invalidEmbedding }
        for index in result.indices {
            result[index] /= norm
        }
        return result
    }

    /// Protocol convenience: detects the largest face in an image, then embeds its aligned crop.
    func computeEmbedding(for faceImage: CGImage) async throws -> [Float] {
        guard let face = try await detectFaces(in: faceImage).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            throw SceneCoreMLFacePipelineError.noFaceDetected
        }
        return try await embedding(for: faceImage, landmarks: face.landmarks)
    }

    // MARK: Model loading and validation

    private static func loadModel(named name: String, from bundle: Bundle, configuration: MLModelConfiguration) throws -> MLModel {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: "SceneModels")
                ?? bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw SceneCoreMLFacePipelineError.missingModel(name)
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func validateYuNet(_ model: MLModel) throws {
        try validateFeature(model, name: "YuNet", inputName: "frame_input", shape: [1, 3, 640, 640])
        let outputs: [(String, [Int])] = [
            ("var_762", [1, 6400, 1]), ("var_779", [1, 1600, 1]), ("var_796", [1, 400, 1]),
            ("var_813", [1, 6400, 1]), ("var_830", [1, 1600, 1]), ("var_847", [1, 400, 1]),
            ("var_863", [1, 6400, 4]), ("var_879", [1, 1600, 4]), ("var_895", [1, 400, 4]),
            ("var_911", [1, 6400, 10]), ("var_927", [1, 1600, 10]), ("var_943", [1, 400, 10])
        ]
        for (name, shape) in outputs {
            try validateFeature(model, name: "YuNet", outputName: name, shape: shape)
        }
    }

    private static func validateSFace(_ model: MLModel) throws {
        try validateFeature(model, name: "SFace", inputName: "face_input", shape: [1, 3, 112, 112])
        try validateFeature(model, name: "SFace", outputName: "var_811", shape: [1, 128])
    }

    private static func validateFeature(_ model: MLModel, name: String, inputName: String, shape: [Int]) throws {
        let description = model.modelDescription.inputDescriptionsByName[inputName]
        try validateFeatureDescription(description, model: name, feature: inputName, shape: shape)
    }

    private static func validateFeature(_ model: MLModel, name: String, outputName: String, shape: [Int]) throws {
        let description = model.modelDescription.outputDescriptionsByName[outputName]
        try validateFeatureDescription(description, model: name, feature: outputName, shape: shape)
    }

    private static func validateFeatureDescription(_ description: MLFeatureDescription?, model: String, feature: String, shape: [Int]) throws {
        let actualShape = description?.multiArrayConstraint?.shape.map(\.intValue)
        let expected = "Float32 multi-array \(shape)"
        let actual = description.map { featureDescription in
            "\(featureDescription.type), \(featureDescription.multiArrayConstraint?.shape.map(\.intValue) ?? []) \(String(describing: featureDescription.multiArrayConstraint?.dataType))"
        } ?? "missing"
        guard description?.type == .multiArray,
              actualShape == shape,
              description?.multiArrayConstraint?.dataType == .float32 else {
            throw SceneCoreMLFacePipelineError.invalidModelFeature(model: model, feature: feature, expected: expected, actual: actual)
        }
    }

    // MARK: YuNet decoding and NMS

    private static func outputArray(_ name: String, from provider: MLFeatureProvider) throws -> MLMultiArray {
        guard let output = provider.featureValue(for: name)?.multiArrayValue,
              output.dataType == .float32 else {
            throw SceneCoreMLFacePipelineError.invalidModelFeature(
                model: "Core ML",
                feature: name,
                expected: "Float32 multi-array output",
                actual: "missing or incompatible output"
            )
        }
        return output
    }

    private static func makeMultiArray(shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        var expectedStrides = Array(repeating: 1, count: shape.count)
        if shape.count > 1 {
            for index in stride(from: shape.count - 2, through: 0, by: -1) {
                expectedStrides[index] = expectedStrides[index + 1] * shape[index + 1]
            }
        }
        let actualStrides = array.strides.map(\.intValue)
        guard actualStrides == expectedStrides else {
            throw SceneCoreMLFacePipelineError.invalidModelFeature(
                model: "Input tensor",
                feature: "NCHW",
                expected: "contiguous strides \(expectedStrides)",
                actual: "strides \(actualStrides)"
            )
        }
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        for index in 0..<array.count {
            pointer[index] = 0
        }
        return array
    }

    private static func clampedProbability(_ value: Float32) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, Float(value)))
    }

    private static func nonMaximumSuppression(_ proposals: [FaceProposal], threshold: CGFloat) -> [FaceProposal] {
        let sorted = proposals.sorted { $0.confidence > $1.confidence }
        var selected: [FaceProposal] = []
        selected.reserveCapacity(sorted.count)
        for proposal in sorted {
            guard !selected.contains(where: { intersectionOverUnion($0.boundingBox, proposal.boundingBox) > threshold }) else {
                continue
            }
            selected.append(proposal)
        }
        return selected
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }

    // MARK: Image preparation and five-point alignment

    private static func drawRGBA(_ image: CGImage, canvasWidth: Int, canvasHeight: Int, destinationRect: CGRect) throws -> [UInt8] {
        guard canvasWidth > 0, canvasHeight > 0 else { throw SceneCoreMLFacePipelineError.invalidImage }
        let bytesPerRow = canvasWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * canvasHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let succeeded = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: canvasWidth,
                height: canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: destinationRect)
            return true
        }
        guard succeeded else { throw SceneCoreMLFacePipelineError.invalidImage }
        return pixels
    }

    private static func similarityTransform(source: [CGPoint], destination: [CGPoint]) throws -> SimilarityTransform {
        guard source.count == 5, destination.count == 5 else {
            throw SceneCoreMLFacePipelineError.invalidLandmarks
        }
        let sourceMean = meanPoint(source)
        let destinationMean = meanPoint(destination)
        var numeratorA: CGFloat = 0
        var numeratorB: CGFloat = 0
        var denominator: CGFloat = 0

        for index in source.indices {
            let sx = source[index].x - sourceMean.x
            let sy = source[index].y - sourceMean.y
            let dx = destination[index].x - destinationMean.x
            let dy = destination[index].y - destinationMean.y
            numeratorA += sx * dx + sy * dy
            numeratorB += sx * dy - sy * dx
            denominator += sx * sx + sy * sy
        }
        guard denominator > 1e-12 else { throw SceneCoreMLFacePipelineError.invalidLandmarks }
        let a = numeratorA / denominator
        let b = numeratorB / denominator
        let tx = destinationMean.x - (a * sourceMean.x - b * sourceMean.y)
        let ty = destinationMean.y - (b * sourceMean.x + a * sourceMean.y)
        guard a.isFinite, b.isFinite, tx.isFinite, ty.isFinite, (a * a + b * b) > 1e-12 else {
            throw SceneCoreMLFacePipelineError.invalidLandmarks
        }
        return SimilarityTransform(a: a, b: b, tx: tx, ty: ty)
    }

    private static func meanPoint(_ points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        return CGPoint(
            x: points.reduce(CGFloat.zero) { $0 + $1.x } / count,
            y: points.reduce(CGFloat.zero) { $0 + $1.y } / count
        )
    }

    private static func sampleBilinear(_ pixels: [UInt8], width: Int, height: Int, x: CGFloat, y: CGFloat) -> (Float, Float, Float) {
        guard x.isFinite, y.isFinite else { return (0, 0, 0) }
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = x0 + 1
        let y1 = y0 + 1
        let dx = Float(x - CGFloat(x0))
        let dy = Float(y - CGFloat(y0))

        func component(_ px: Int, _ py: Int, _ channel: Int) -> Float {
            guard px >= 0, px < width, py >= 0, py < height else { return 0 }
            return Float(pixels[(py * width + px) * 4 + channel])
        }
        func interpolate(_ channel: Int) -> Float {
            let top = component(x0, y0, channel) * (1 - dx) + component(x1, y0, channel) * dx
            let bottom = component(x0, y1, channel) * (1 - dx) + component(x1, y1, channel) * dx
            return top * (1 - dy) + bottom * dy
        }
        return (interpolate(0), interpolate(1), interpolate(2))
    }
}

private struct YuNetHead {
    let stride: Int
    let columns: Int
    let rows: Int
    let classification: String
    let objectness: String
    let box: String
    let landmarks: String
}

private struct FaceProposal {
    let boundingBox: CGRect
    let landmarks: [CGPoint]
    let confidence: Float
}

private struct SimilarityTransform {
    let a: CGFloat
    let b: CGFloat
    let tx: CGFloat
    let ty: CGFloat

    func inverseMap(x: CGFloat, y: CGFloat) -> CGPoint {
        let determinant = a * a + b * b
        let targetX = x - tx
        let targetY = y - ty
        return CGPoint(
            x: (a * targetX + b * targetY) / determinant,
            y: (-b * targetX + a * targetY) / determinant
        )
    }
}
