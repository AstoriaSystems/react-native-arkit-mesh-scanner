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

    // Thread safety - use NSLock for all mesh data access
    private let meshLock = NSLock()

    // Throttling for distance culling
    private var lastDistanceCheckTime: Date = Date()
    private let distanceCheckInterval: TimeInterval = 0.5 // Check distance 2x per second

    // Throttling for mesh updates per anchor - increased interval for better performance
    private var lastMeshUpdateTimes: [UUID: Date] = [:]
    private let minMeshUpdateInterval: TimeInterval = 1.0 // Don't update same anchor more than 1x/second

    // Frame capture - reduced frequency for better performance
    private var capturedFrames: [CapturedFrame] = []
    private var lastCaptureTime: Date = Date()
    private let captureInterval: TimeInterval = 2.0 // Capture frames every 2 seconds
    private let maxFrames: Int = 25 // Reduced from 50

    // Controllers
    private let previewController = PreviewController()
    private let meshExporter = MeshExporter()

    // Serial queue for mesh processing to avoid race conditions
    private let meshProcessingQueue = DispatchQueue(label: "com.arkitmeshscanner.meshprocessing", qos: .userInitiated)

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

    @objc public var maxRenderDistance: Float = 1000.0 // meters - effectively disabled by default

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

        meshLock.lock()
        meshAnchors.removeAll()
        capturedFrames.removeAll()
        lastMeshUpdateTimes.removeAll()
        meshLock.unlock()

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
        meshLock.lock()
        let anchorsSnapshot = meshAnchors
        let framesSnapshot = capturedFrames
        let entitiesSnapshot = meshAnchorEntities
        meshLock.unlock()

        guard !anchorsSnapshot.isEmpty else { return }

        isScanning = false

        // Hide AR mesh entities
        for (_, anchorEntity) in entitiesSnapshot {
            anchorEntity.isEnabled = false
        }

        previewController.enterPreviewMode(
            arView: arView,
            meshAnchors: anchorsSnapshot,
            capturedFrames: framesSnapshot,
            meshColor: meshColorHex
        )
    }

    @objc public func exitPreviewMode() {
        previewController.exitPreviewMode()

        meshLock.lock()
        let entitiesSnapshot = meshAnchorEntities
        meshLock.unlock()

        // Show AR mesh entities again
        for (_, anchorEntity) in entitiesSnapshot {
            anchorEntity.isEnabled = true
        }

        startCameraPreview()
    }

    @objc public func clearMesh() {
        if previewController.isActive {
            exitPreviewMode()
        }

        meshLock.lock()
        meshAnchors.removeAll()
        capturedFrames.removeAll()
        lastMeshUpdateTimes.removeAll()
        meshLock.unlock()

        clearMeshEntities()
        sendMeshUpdate()
    }

    @objc public func exportMesh(filename: String, completion: @escaping (String?, Int, Int, String?) -> Void) {
        // Take snapshots under lock
        meshLock.lock()
        let anchorsSnapshot = meshAnchors
        let framesSnapshot = capturedFrames
        meshLock.unlock()

        meshExporter.exportMesh(
            meshAnchors: anchorsSnapshot,
            filename: filename,
            capturedFrames: framesSnapshot
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
        meshLock.lock()
        defer { meshLock.unlock() }

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
        meshLock.lock()
        defer { meshLock.unlock() }

        for (_, anchorEntity) in meshAnchorEntities {
            arView.scene.removeAnchor(anchorEntity)
        }
        meshAnchorEntities.removeAll()
        meshModelEntities.removeAll()
    }

    private func updateMeshVisibility() {
        meshLock.lock()
        defer { meshLock.unlock() }

        for (_, entity) in meshModelEntities {
            entity.isEnabled = showMesh
        }
    }

    private func updateMeshMaterial() {
        meshLock.lock()
        defer { meshLock.unlock() }

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
        meshLock.lock()
        if let lastUpdate = lastMeshUpdateTimes[anchorId],
           now.timeIntervalSince(lastUpdate) < minMeshUpdateInterval {
            meshLock.unlock()
            return
        }
        lastMeshUpdateTimes[anchorId] = now
        meshLock.unlock()

        performMeshEntityUpdate(for: anchor)
    }

    /// Thread-safe structure to hold copied mesh geometry data
    private struct MeshGeometrySnapshot {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
        let transform: simd_float4x4
    }

    /// Safely extract mesh geometry data from ARMeshAnchor
    /// Creates a complete copy of the geometry data to avoid race conditions with ARKit's buffers
    /// Returns nil if the data cannot be safely copied
    private func extractMeshGeometry(from anchor: ARMeshAnchor) -> MeshGeometrySnapshot? {
        // Capture all values we need from the anchor immediately
        // ARKit can update the anchor at any time, so we snapshot everything first
        let geometry = anchor.geometry
        let transform = anchor.transform

        // Get metadata before accessing buffers
        let vertexCount = geometry.vertices.count
        let faceCount = geometry.faces.count

        guard vertexCount > 0, faceCount > 0 else { return nil }

        // Capture buffer metadata
        let vertexStride = geometry.vertices.stride
        let vertexOffset = geometry.vertices.offset
        let vertexBufferLength = geometry.vertices.buffer.length

        let indexCountPerPrimitive = geometry.faces.indexCountPerPrimitive
        let bytesPerIndex = geometry.faces.bytesPerIndex
        let faceBufferLength = geometry.faces.buffer.length

        // Validate buffer sizes to prevent out-of-bounds access
        let requiredVertexBytes = vertexOffset + (vertexStride * vertexCount)
        let requiredFaceBytes = bytesPerIndex * faceCount * indexCountPerPrimitive

        guard requiredVertexBytes <= vertexBufferLength,
              requiredFaceBytes <= faceBufferLength else {
            print("ARKitMeshScanner: Buffer size mismatch, skipping anchor")
            return nil
        }

        // Create safe copies of the raw buffer data
        // This is the critical section - copy raw bytes as fast as possible
        var vertexData = Data(count: vertexBufferLength)
        var faceData = Data(count: faceBufferLength)

        // Copy vertex buffer
        let vertexBuffer = geometry.vertices.buffer
        vertexData.withUnsafeMutableBytes { destPtr in
            guard let dest = destPtr.baseAddress else { return }
            memcpy(dest, vertexBuffer.contents(), vertexBufferLength)
        }

        // Copy face buffer
        let faceBuffer = geometry.faces.buffer
        faceData.withUnsafeMutableBytes { destPtr in
            guard let dest = destPtr.baseAddress else { return }
            memcpy(dest, faceBuffer.contents(), faceBufferLength)
        }

        // Now process the copied data safely - ARKit can no longer affect us
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)

        vertexData.withUnsafeBytes { rawPtr in
            guard let basePtr = rawPtr.baseAddress else { return }

            for i in 0..<vertexCount {
                let offset = vertexOffset + vertexStride * i

                // Bounds check
                guard offset + MemoryLayout<SIMD3<Float>>.size <= vertexBufferLength else {
                    continue
                }

                let vertexPtr = basePtr.advanced(by: offset)
                let vertex = vertexPtr.assumingMemoryBound(to: SIMD3<Float>.self).pointee

                // Validate vertex data - skip NaN or infinite values
                if vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite {
                    positions.append(vertex)
                }
            }
        }

        guard positions.count >= 3 else { return nil }

        // Process face indices
        var indices: [UInt32] = []
        indices.reserveCapacity(faceCount * indexCountPerPrimitive)
        let maxValidIndex = UInt32(positions.count - 1)

        faceData.withUnsafeBytes { rawPtr in
            guard let basePtr = rawPtr.baseAddress else { return }

            for i in 0..<faceCount {
                var faceIndices: [UInt32] = []
                faceIndices.reserveCapacity(indexCountPerPrimitive)
                var validFace = true

                for j in 0..<indexCountPerPrimitive {
                    let offset = bytesPerIndex * (i * indexCountPerPrimitive + j)

                    // Bounds check
                    guard offset + bytesPerIndex <= faceBufferLength else {
                        validFace = false
                        break
                    }

                    let indexPtr = basePtr.advanced(by: offset)
                    let index: UInt32

                    if bytesPerIndex == 4 {
                        index = indexPtr.assumingMemoryBound(to: UInt32.self).pointee
                    } else {
                        index = UInt32(indexPtr.assumingMemoryBound(to: UInt16.self).pointee)
                    }

                    // Validate index is within bounds of our position array
                    if index > maxValidIndex {
                        validFace = false
                        break
                    }
                    faceIndices.append(index)
                }

                if validFace {
                    indices.append(contentsOf: faceIndices)
                }
            }
        }

        guard indices.count >= 3 else { return nil }

        return MeshGeometrySnapshot(positions: positions, indices: indices, transform: transform)
    }

    /// Thread-safe mesh entity update
    /// CRITICAL: Must extract geometry data IMMEDIATELY on the calling thread before ARKit can invalidate the buffer
    private func performMeshEntityUpdate(for anchor: ARMeshAnchor) {
        let anchorId = anchor.identifier

        // CRITICAL: Extract geometry data IMMEDIATELY on current thread (main thread from ARSession delegate)
        // ARKit can invalidate the anchor's buffer at any time, so we must copy it NOW
        // Do NOT pass the anchor to a background queue - the buffer may be invalid by then
        guard let snapshot = extractMeshGeometry(from: anchor) else {
            return
        }

        // Now process the safely copied data on background queue for performance
        meshProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Create mesh descriptor from the safely copied data
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(snapshot.positions)
            descriptor.primitives = .triangles(snapshot.indices)

            do {
                let meshResource = try MeshResource.generate(from: [descriptor])

                // Update UI on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    let color = UIColor(hex: self.meshColorHex) ?? UIColor(red: 0, green: 0.7, blue: 1, alpha: 1)

                    self.meshLock.lock()
                    defer { self.meshLock.unlock() }

                    if let existingModel = self.meshModelEntities[anchorId] {
                        existingModel.model?.mesh = meshResource
                        existingModel.transform = Transform(matrix: snapshot.transform)
                    } else {
                        var material = UnlitMaterial(color: color.withAlphaComponent(0.9))
                        material.blending = .transparent(opacity: 0.9)
                        let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
                        modelEntity.transform = Transform(matrix: snapshot.transform)

                        let anchorEntity = AnchorEntity(world: .zero)
                        anchorEntity.addChild(modelEntity)
                        self.arView.scene.addAnchor(anchorEntity)

                        self.meshAnchorEntities[anchorId] = anchorEntity
                        self.meshModelEntities[anchorId] = modelEntity
                    }
                }
            } catch {
                print("ARKitMeshScanner: Failed to create mesh: \(error)")
            }
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
        // Distance-based culling is now disabled by default for better user experience
        // Users reported confusion when mesh was not fully visible during scanning
        // If maxRenderDistance is set to a very large value (>100), skip distance checks entirely
        guard maxRenderDistance < 100, let cameraTransform = currentCameraTransform else { return }

        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        meshLock.lock()
        let anchorsSnapshot = meshAnchors
        let entitiesSnapshot = meshModelEntities
        meshLock.unlock()

        for (uuid, anchor) in anchorsSnapshot {
            guard let modelEntity = entitiesSnapshot[uuid] else { continue }

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

        meshLock.lock()
        let currentCount = capturedFrames.count
        meshLock.unlock()

        guard currentCount < maxFrames else { return }

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

            meshLock.lock()
            capturedFrames.append(capturedFrame)
            let newCount = capturedFrames.count
            meshLock.unlock()

            print("Captured frame \(newCount)/\(maxFrames)")
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
                meshLock.lock()
                meshAnchors[meshAnchor.identifier] = meshAnchor
                meshLock.unlock()

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
                meshLock.lock()
                meshAnchors[meshAnchor.identifier] = meshAnchor
                meshLock.unlock()

                updateMeshEntity(for: meshAnchor)
            }
        }
        throttledSendUpdate()
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        meshLock.lock()
        defer { meshLock.unlock() }

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
