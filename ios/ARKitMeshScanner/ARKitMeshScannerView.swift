//
//  ARKitMeshScannerView.swift
//  react-native-arkit-mesh-scanner
//
//  Copyright (c) 2025 Astoria Systems GmbH
//  Author: Mergim Mavraj
//
//  RAM-OPTIMIZED VERSION: Uses ARKit's built-in debug wireframe for visualization.
//  No custom MeshResource/ModelEntity = minimal RAM usage.
//  Disk storage handles export - no mesh data kept in RAM.


import UIKit
import ARKit
import RealityKit

/// React Native native view for ARKit mesh scanning with LiDAR.
/// Memory-safe implementation with automatic cleanup and pressure monitoring.
@objc(ARKitMeshScannerView)
public class ARKitMeshScannerView: UIView {

    // MARK: - Properties

    private var arView: ARView!
    private var isScanning: Bool = false
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 0.2  // Slower updates = less CPU

    // ZERO RAM VISUALIZATION:
    // Uses ARKit's built-in debug wireframe (.showSceneUnderstanding)
    // ARKit manages mesh internally - we never copy or store mesh data in RAM
    // Disk storage handles export asynchronously

    // Disk storage for export only (writes happen on background queue)
    private let diskMeshStorage = DiskMeshStorage()

    // Controllers
    private let previewController = PreviewController()

    // Per-anchor throttle to reduce disk writes
    private var lastAnchorWriteTime: [UUID: Date] = [:]
    private let anchorWriteInterval: TimeInterval = 1.0  // Max 1 write per anchor per second

    // Memory pressure observer
    private var memoryWarningObserver: NSObjectProtocol?

    // MARK: - Configuration Properties

    @objc public var showMesh: Bool = true {
        didSet { updateMeshVisibility() }
    }

    @objc public var meshColorHex: String = "#0080FF"

    @objc public var wireframe: Bool = false

    @objc public var enableOcclusion: Bool = true {
        didSet { updateOcclusionSettings() }
    }

    @objc public var maxRenderDistance: Float = 5.0

    // MARK: - React Native Callbacks

    @objc public var onMeshUpdate: RCTDirectEventBlock?
    @objc public var onScanComplete: RCTDirectEventBlock?
    @objc public var onError: RCTDirectEventBlock?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupARView()
        setupPreviewController()
        setupMemoryPressureMonitoring()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupARView()
        setupPreviewController()
        setupMemoryPressureMonitoring()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        diskMeshStorage.clear()
    }

    /// Setup system memory pressure monitoring
    private func setupMemoryPressureMonitoring() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("⚠️ SYSTEM MEMORY WARNING")
            // With debug wireframe, we have nothing to evict
            // ARKit manages its own memory
        }
    }

    private func setupARView() {
        arView = ARView(frame: bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.session.delegate = self

        // Ensure camera feed is visible
        arView.environment.background = .cameraFeed()

        // Enable occlusion if requested
        if enableOcclusion {
            arView.environment.sceneUnderstanding.options = [.occlusion]
        }

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

        // Clear previous data
        diskMeshStorage.clear()
        lastAnchorWriteTime.removeAll()

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .automatic
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]

        // TRACKING STABILITY: Enable all available features for robust tracking
        // smoothedSceneDepth provides more stable depth data during fast movement
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // Enable high-resolution frame capture for better feature detection in low light
        if #available(iOS 16.0, *) {
            configuration.videoHDRAllowed = true
        }

        // Maximize feature tracking quality
        configuration.isAutoFocusEnabled = true
        configuration.isLightEstimationEnabled = true

        // MEMORY SAFETY: Reset session completely to free ARKit's internal mesh data
        // NOTE: Only reset tracking at start, NOT during scanning (causes tracking loss!)
        arView.session.run(configuration, options: [.resetSceneReconstruction, .removeExistingAnchors, .resetTracking])
        isScanning = true

        // MEMORY SAFE: Use ARKit's debug wireframe only
        // This uses ZERO additional RAM - ARKit manages mesh internally
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }

        sendMeshUpdate()
    }

    @objc public func stopScanning() {
        isScanning = false
        // Keep debug visualization visible after stopping
        sendMeshUpdate()
    }

    @objc public func enterPreviewMode() {
        // Check if we have any mesh data (from disk storage)
        let stats = diskMeshStorage.getStats()
        guard stats.anchorCount > 0 else { return }

        isScanning = false

        // Hide ARKit's mesh for preview mode
        arView.debugOptions.remove(.showSceneUnderstanding)

        // Load complete mesh data from disk storage for preview
        diskMeshStorage.loadAllMeshData { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let meshData):
                self.previewController.enterPreviewMode(
                    arView: self.arView,
                    vertices: meshData.vertices,
                    faces: meshData.faces,
                    meshColor: self.meshColorHex
                )
            case .failure(let error):
                print("Failed to load mesh data for preview: \(error)")
                // Restore mesh visualization on failure
                if self.showMesh {
                    self.arView.debugOptions.insert(.showSceneUnderstanding)
                }
            }
        }
    }

    @objc public func exitPreviewMode() {
        previewController.exitPreviewMode()

        // Restore ARKit's mesh visualization
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }

        startCameraPreview()
    }

    @objc public func clearMesh() {
        if previewController.isActive {
            exitPreviewMode()
        }

        diskMeshStorage.clear()
        lastAnchorWriteTime.removeAll()

        sendMeshUpdate()
    }

    @objc public func exportMesh(filename: String, completion: @escaping (String?, Int, Int, String?) -> Void) {
        // Use disk storage for complete export
        diskMeshStorage.exportToOBJ(filename: filename) { result in
            switch result {
            case .success(let exportResult):
                completion(exportResult.path, exportResult.vertexCount, exportResult.faceCount, nil)
            case .failure(let error):
                completion(nil, 0, 0, error.localizedDescription)
            }
        }
    }

    @objc public func getMeshStats() -> [String: Any] {
        // Use disk stats for accurate totals
        let diskStats = diskMeshStorage.getStats()

        return [
            "anchorCount": diskStats.anchorCount,
            "vertexCount": diskStats.vertexCount,
            "faceCount": diskStats.faceCount,
            "isScanning": isScanning
        ]
    }

    // MARK: - Private Methods

    /// Update mesh visibility using ARKit's debug options
    /// ZERO RAM: Only toggles debugOptions flag
    private func updateMeshVisibility() {
        if showMesh && isScanning {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
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

    /// Check if we should write this anchor (throttle per-anchor)
    private func shouldWriteAnchor(_ anchorId: UUID) -> Bool {
        let now = Date()
        if let lastWrite = lastAnchorWriteTime[anchorId] {
            if now.timeIntervalSince(lastWrite) < anchorWriteInterval {
                return false
            }
        }
        lastAnchorWriteTime[anchorId] = now
        return true
    }
}

// MARK: - ARSessionDelegate
// MEMORY-EFFICIENT: Uses ARKit's built-in visualization, only stores to disk for export

extension ARKitMeshScannerView: ARSessionDelegate {

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Nothing to do - ARKit handles visualization internally
    }

    /// Handle new mesh anchors: store to disk only (no RAM storage)
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Throttle per-anchor to reduce disk writes
                if shouldWriteAnchor(meshAnchor.identifier) {
                    diskMeshStorage.storeAnchor(meshAnchor)
                }
            }
        }

        throttledSendUpdate()
    }

    /// Handle updated mesh anchors: update disk storage only
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Throttle per-anchor to reduce disk writes
                if shouldWriteAnchor(meshAnchor.identifier) {
                    diskMeshStorage.storeAnchor(meshAnchor)
                }
            }
        }

        throttledSendUpdate()
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                diskMeshStorage.removeAnchor(meshAnchor.identifier)
                lastAnchorWriteTime.removeValue(forKey: meshAnchor.identifier)
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
            print("⚠️ Tracking not available")
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                print("⚠️ Tracking limited: Excessive motion - slow down")
            case .insufficientFeatures:
                print("⚠️ Tracking limited: Insufficient features - point at textured surfaces")
            case .initializing:
                print("ℹ️ Tracking initializing...")
            case .relocalizing:
                print("ℹ️ Tracking relocalizing...")
            @unknown default:
                print("⚠️ Tracking limited: \(reason)")
            }
        case .normal:
            print("✅ Tracking normal")
        }
    }

    /// Handle session interruption (e.g., phone call, app switch)
    public func sessionWasInterrupted(_ session: ARSession) {
        print("⚠️ Session interrupted")
    }

    /// Handle session interruption end - attempt to resume tracking
    public func sessionInterruptionEnded(_ session: ARSession) {
        print("ℹ️ Session interruption ended, attempting to resume...")
        // Don't reset tracking - just let ARKit try to relocalize
        // This preserves the existing mesh data
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
