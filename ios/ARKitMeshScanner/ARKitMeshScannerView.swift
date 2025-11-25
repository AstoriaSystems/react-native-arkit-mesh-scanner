//
//  ARKitMeshScannerView.swift
//  react-native-arkit-mesh-scanner
//
//  Copyright (c) 2025 Astoria Systems GmbH
//  Author: Mergim Mavraj
//
//  This file is part of the React Native ARKit Mesh Scanner.
//
//  Dual License:
//  ---------------------------------------------------------------------------
//  Commercial License
//  ---------------------------------------------------------------------------
//  If you purchased a commercial license from Astoria Systems GmbH, you are
//  granted the rights defined in the commercial license agreement. This license
//  permits the use of this software in closed-source, proprietary, or
//  competitive commercial products.
//
//  To obtain a commercial license, please contact:
//  licensing@astoria.systems
//
//  ---------------------------------------------------------------------------
//  Open Source License (AGPL-3.0)
//  ---------------------------------------------------------------------------
//  If you have not purchased a commercial license, this software is offered
//  under the terms of the GNU Affero General Public License v3.0 (AGPL-3.0).
//
//  You may use, modify, and redistribute this software under the conditions of
//  the AGPL-3.0. Any software that incorporates or interacts with this code
//  over a network must also be released under the AGPL-3.0.
//
//  A copy of the AGPL-3.0 license is provided in the repository's LICENSE file
//  or at: https://www.gnu.org/licenses/agpl-3.0.html
//
//  ---------------------------------------------------------------------------
//  Disclaimer
//  ---------------------------------------------------------------------------
//  This software is provided "AS IS", without warranty of any kind, express or
//  implied, including but not limited to the warranties of merchantability,
//  fitness for a particular purpose and noninfringement. In no event shall the
//  authors or copyright holders be liable for any claim, damages or other
//  liability, whether in an action of contract, tort or otherwise, arising from,
//  out of or in connection with the software or the use or other dealings in
//  the software.


import UIKit
import ARKit
import RealityKit

/// React Native native view for ARKit mesh scanning with LiDAR.
@objc(ARKitMeshScannerView)
public class ARKitMeshScannerView: UIView {

    // MARK: - Properties

    private var arView: ARView!
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var meshAnchorEntities: [UUID: AnchorEntity] = [:]
    private var meshModelEntities: [UUID: ModelEntity] = [:]
    private var isScanning: Bool = false
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 0.15

    // Throttling for distance culling
    private var lastDistanceCheckTime: Date = Date()
    private let distanceCheckInterval: TimeInterval = 0.5 // Check distance 2x per second

    // Throttling for mesh updates per anchor
    private var lastMeshUpdateTimes: [UUID: Date] = [:]
    private let minMeshUpdateInterval: TimeInterval = 0.5 // Don't update same anchor more than 2x/second

    // Frame capture
    private var capturedFrames: [CapturedFrame] = []
    private var lastCaptureTime: Date = Date()
    private let captureInterval: TimeInterval = 0.5
    private let maxFrames: Int = 50

    // Controllers
    private let previewController = PreviewController()
    private let meshExporter = MeshExporter()

    // MARK: - Configuration Properties

    @objc public var showMesh: Bool = true {
        didSet { updateMeshVisibility() }
    }

    @objc public var meshColorHex: String = "#0080FF" {
        didSet { updateMeshMaterial() }
    }

    @objc public var wireframe: Bool = false {
        didSet { updateMeshMaterial() }
    }

    @objc public var enableOcclusion: Bool = true {
        didSet { updateOcclusionSettings() }
    }

    @objc public var maxRenderDistance: Float = 5.0 // meters

    private var currentCameraTransform: simd_float4x4?

    // MARK: - React Native Callbacks

    @objc public var onMeshUpdate: RCTDirectEventBlock?
    @objc public var onScanComplete: RCTDirectEventBlock?
    @objc public var onError: RCTDirectEventBlock?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupARView()
        setupPreviewController()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupARView()
        setupPreviewController()
    }

    private func setupARView() {
        arView = ARView(frame: bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.session.delegate = self

        // Enable occlusion so mesh behind walls is hidden
        arView.environment.sceneUnderstanding.options = [.occlusion]

        addSubview(arView)
        startCameraPreview()
    }

    private func updateOcclusionSettings() {
        if enableOcclusion {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            arView.environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }

    private func setupPreviewController() {
        previewController.delegate = self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
    }

    private func startCameraPreview() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.worldAlignment = .gravity
        arView.session.run(configuration)
    }

    // MARK: - Public Methods

    @objc public func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            sendError("LiDAR ist auf diesem Gerät nicht verfügbar")
            return
        }

        // Exit preview if active
        if previewController.isActive {
            exitPreviewMode()
        }

        clearMeshEntities()
        meshAnchors.removeAll()
        capturedFrames.removeAll()

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .automatic
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        arView.session.run(configuration, options: [.removeExistingAnchors])
        isScanning = true

        sendMeshUpdate()
    }

    @objc public func stopScanning() {
        isScanning = false
        sendMeshUpdate()
    }

    @objc public func enterPreviewMode() {
        guard !meshAnchors.isEmpty else { return }

        isScanning = false

        // Hide AR mesh entities
        for (_, anchorEntity) in meshAnchorEntities {
            anchorEntity.isEnabled = false
        }

        previewController.enterPreviewMode(
            arView: arView,
            meshAnchors: meshAnchors,
            capturedFrames: capturedFrames,
            meshColor: meshColorHex
        )
    }

    @objc public func exitPreviewMode() {
        previewController.exitPreviewMode()

        // Show AR mesh entities again
        for (_, anchorEntity) in meshAnchorEntities {
            anchorEntity.isEnabled = true
        }

        startCameraPreview()
    }

    @objc public func clearMesh() {
        if previewController.isActive {
            exitPreviewMode()
        }
        meshAnchors.removeAll()
        clearMeshEntities()
        sendMeshUpdate()
    }

    @objc public func exportMesh(filename: String, completion: @escaping (String?, Int, Int, String?) -> Void) {
        meshExporter.exportMesh(
            meshAnchors: meshAnchors,
            filename: filename,
            capturedFrames: capturedFrames
        ) { result in
            switch result {
            case .success(let exportResult):
                completion(exportResult.path, exportResult.vertexCount, exportResult.faceCount, nil)
            case .failure(let error):
                completion(nil, 0, 0, error.localizedDescription)
            }
        }
    }

    @objc public func getMeshStats() -> [String: Any] {
        var totalVertices = 0
        var totalFaces = 0

        for (_, anchor) in meshAnchors {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }

        return [
            "anchorCount": meshAnchors.count,
            "vertexCount": totalVertices,
            "faceCount": totalFaces,
            "isScanning": isScanning
        ]
    }

    // MARK: - Private Methods

    private func clearMeshEntities() {
        for (_, anchorEntity) in meshAnchorEntities {
            arView.scene.removeAnchor(anchorEntity)
        }
        meshAnchorEntities.removeAll()
        meshModelEntities.removeAll()
    }

    private func updateMeshVisibility() {
        for (_, entity) in meshModelEntities {
            entity.isEnabled = showMesh
        }
    }

    private func updateMeshMaterial() {
        let color = UIColor(hex: meshColorHex) ?? UIColor(red: 0, green: 0.7, blue: 1, alpha: 1)
        for (_, entity) in meshModelEntities {
            applyMaterial(to: entity, color: color)
        }
    }

    private func applyMaterial(to entity: ModelEntity, color: UIColor) {
        var material = UnlitMaterial(color: color.withAlphaComponent(0.9))
        material.blending = .transparent(opacity: 0.9)
        entity.model?.materials = [material]
    }

    private func sendMeshUpdate() {
        let stats = getMeshStats()
        onMeshUpdate?(stats)
    }

    private func sendError(_ message: String) {
        onError?(["message": message])
    }

    private func throttledSendUpdate() {
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) > updateInterval {
            lastUpdateTime = now
            sendMeshUpdate()
        }
    }

    /// Update mesh entity with per-anchor throttling
    private func updateMeshEntity(for anchor: ARMeshAnchor) {
        guard showMesh else { return }

        let anchorId = anchor.identifier
        let now = Date()

        // Throttle updates per anchor - skip if updated recently
        if let lastUpdate = lastMeshUpdateTimes[anchorId],
           now.timeIntervalSince(lastUpdate) < minMeshUpdateInterval {
            return
        }
        lastMeshUpdateTimes[anchorId] = now

        performMeshEntityUpdate(for: anchor)
    }

    /// Direct mesh entity update on main thread
    private func performMeshEntityUpdate(for anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        var descriptor = MeshDescriptor()

        // Get vertices directly from ARKit
        let vertices = geometry.vertices
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertices.count)
        let vertexBuffer = vertices.buffer.contents()

        for i in 0..<vertices.count {
            let vertexPointer = vertexBuffer.advanced(by: vertices.offset + vertices.stride * i)
            let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            positions.append(vertex)
        }
        descriptor.positions = MeshBuffer(positions)

        // Get faces directly
        let faces = geometry.faces
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * faces.indexCountPerPrimitive)
        let faceBuffer = faces.buffer.contents()

        for i in 0..<faces.count {
            for j in 0..<faces.indexCountPerPrimitive {
                let indexPointer = faceBuffer.advanced(by: faces.bytesPerIndex * (i * faces.indexCountPerPrimitive + j))
                if faces.bytesPerIndex == 4 {
                    indices.append(indexPointer.assumingMemoryBound(to: UInt32.self).pointee)
                } else {
                    indices.append(UInt32(indexPointer.assumingMemoryBound(to: UInt16.self).pointee))
                }
            }
        }
        descriptor.primitives = .triangles(indices)

        do {
            let meshResource = try MeshResource.generate(from: [descriptor])
            let color = UIColor(hex: meshColorHex) ?? UIColor(red: 0, green: 0.7, blue: 1, alpha: 1)

            if let existingModel = meshModelEntities[anchor.identifier] {
                existingModel.model?.mesh = meshResource
                existingModel.transform = Transform(matrix: anchor.transform)
            } else {
                var material = UnlitMaterial(color: color.withAlphaComponent(0.9))
                material.blending = .transparent(opacity: 0.9)
                let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
                modelEntity.transform = Transform(matrix: anchor.transform)

                let anchorEntity = AnchorEntity(world: .zero)
                anchorEntity.addChild(modelEntity)
                arView.scene.addAnchor(anchorEntity)

                meshAnchorEntities[anchor.identifier] = anchorEntity
                meshModelEntities[anchor.identifier] = modelEntity
            }
        } catch {
            print("Failed to create mesh: \(error)")
        }
    }
}

// MARK: - ARSessionDelegate

extension ARKitMeshScannerView: ARSessionDelegate {

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update camera transform for distance-based culling
        currentCameraTransform = frame.camera.transform

        // Throttle distance checks (expensive with many anchors)
        let now = Date()
        if now.timeIntervalSince(lastDistanceCheckTime) >= distanceCheckInterval {
            lastDistanceCheckTime = now
            updateMeshVisibilityByDistance()
        }

        guard isScanning else { return }

        // Capture frames periodically for texture mapping
        if now.timeIntervalSince(lastCaptureTime) >= captureInterval {
            lastCaptureTime = now
            captureFrame(frame)
        }
    }

    private func updateMeshVisibilityByDistance() {
        guard let cameraTransform = currentCameraTransform else { return }
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        for (uuid, anchor) in meshAnchors {
            guard let modelEntity = meshModelEntities[uuid] else { continue }

            let anchorPosition = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )

            let distance = simd_distance(cameraPosition, anchorPosition)

            // Hide meshes that are too far away
            let shouldBeVisible = showMesh && distance <= maxRenderDistance
            if modelEntity.isEnabled != shouldBeVisible {
                modelEntity.isEnabled = shouldBeVisible
            }
        }
    }

    private func captureFrame(_ frame: ARFrame) {
        switch frame.camera.trackingState {
        case .normal:
            break
        default:
            return
        }
        guard capturedFrames.count < maxFrames else { return }

        if let copiedBuffer = copyPixelBuffer(frame.capturedImage) {
            let capturedFrame = CapturedFrame(
                image: copiedBuffer,
                transform: frame.camera.transform,
                intrinsics: frame.camera.intrinsics,
                imageSize: CGSize(
                    width: CVPixelBufferGetWidth(frame.capturedImage),
                    height: CVPixelBufferGetHeight(frame.capturedImage)
                ),
                timestamp: frame.timestamp
            )
            capturedFrames.append(capturedFrame)
            print("Captured frame \(capturedFrames.count)/\(maxFrames)")
        }
    }

    private func copyPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &newPixelBuffer)

        guard status == kCVReturnSuccess, let newBuffer = newPixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(newBuffer, [])

        let srcY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let dstY = CVPixelBufferGetBaseAddressOfPlane(newBuffer, 0)
        let srcYBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let dstYBytes = CVPixelBufferGetBytesPerRowOfPlane(newBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)

        if let srcY = srcY, let dstY = dstY {
            for row in 0..<heightY {
                memcpy(dstY.advanced(by: row * dstYBytes), srcY.advanced(by: row * srcYBytes), min(srcYBytes, dstYBytes))
            }
        }

        let srcUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let dstUV = CVPixelBufferGetBaseAddressOfPlane(newBuffer, 1)
        let srcUVBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let dstUVBytes = CVPixelBufferGetBytesPerRowOfPlane(newBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        if let srcUV = srcUV, let dstUV = dstUV {
            for row in 0..<heightUV {
                memcpy(dstUV.advanced(by: row * dstUVBytes), srcUV.advanced(by: row * srcUVBytes), min(srcUVBytes, dstUVBytes))
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(newBuffer, [])

        return newBuffer
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors[meshAnchor.identifier] = meshAnchor
                // Create new meshes immediately
                performMeshEntityUpdate(for: meshAnchor)
            }
        }
        throttledSendUpdate()
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors[meshAnchor.identifier] = meshAnchor
                updateMeshEntity(for: meshAnchor)
            }
        }
        throttledSendUpdate()
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors.removeValue(forKey: meshAnchor.identifier)

                if let anchorEntity = meshAnchorEntities[meshAnchor.identifier] {
                    arView.scene.removeAnchor(anchorEntity)
                    meshAnchorEntities.removeValue(forKey: meshAnchor.identifier)
                    meshModelEntities.removeValue(forKey: meshAnchor.identifier)
                }
            }
        }
        sendMeshUpdate()
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        sendError(error.localizedDescription)
    }

    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .notAvailable:
            print("Tracking not available")
        case .limited(let reason):
            print("Tracking limited: \(reason)")
        case .normal:
            print("Tracking normal")
        }
    }
}

// MARK: - PreviewControllerDelegate

extension ARKitMeshScannerView: PreviewControllerDelegate {

    func previewControllerDidEnterPreview(_ controller: PreviewController) {
        print("Entered preview mode")
    }

    func previewControllerDidExitPreview(_ controller: PreviewController) {
        print("Exited preview mode")
    }
}
