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
/// Memory-safe implementation with automatic cleanup and pressure monitoring.
@objc(ARKitMeshScannerView)
public class ARKitMeshScannerView: UIView {

    // MARK: - Properties

    private var arView: ARView!
    private var isScanning: Bool = false
    private var lastUpdateTime: Date = Date()
    private let updateInterval: TimeInterval = 0.15

    // MEMORY-EFFICIENT VISUALIZATION:
    // Uses ARKit's built-in debug wireframe visualization.
    // This is extremely memory efficient because ARKit manages the mesh internally.
    // We only copy mesh data when storing to disk for export.

    // ARKit debug options for mesh visualization
    private let meshDebugOptions: ARView.DebugOptions = [.showSceneUnderstanding]


    // Memory pressure monitoring
    private var lastMemoryCheckTime: Date = Date()
    private let memoryCheckInterval: TimeInterval = 5.0
    private var memoryPressureLevel: Int = 0  // 0=normal, 1=warning, 2=critical

    // Memory thresholds (in MB)
    private let memoryWarningThreshold: UInt64 = 1500
    private let memoryCriticalThreshold: UInt64 = 2000

    // Disk storage for complete export (ALWAYS stores everything)
    private let diskMeshStorage = DiskMeshStorage()

    // Controllers
    private let previewController = PreviewController()

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

    // Legacy prop - kept for backwards compatibility but no longer used
    @objc public var maxRenderDistance: Float = 5.0

    // Legacy prop - dimming doesn't work well with ARKit debug visualization
    @objc public var cameraDimming: Float = 0.0

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
        // Clean up memory pressure observer
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Clean up disk storage
        diskMeshStorage.clear()
    }

    /// Setup system memory pressure monitoring
    private func setupMemoryPressureMonitoring() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemMemoryWarning()
        }
    }

    /// Handle system memory warning
    private func handleSystemMemoryWarning() {
        print("⚠️ SYSTEM MEMORY WARNING")
        memoryPressureLevel = 2
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

        // Reset memory pressure state
        memoryPressureLevel = 0

        // Clear previous data
        diskMeshStorage.clear()

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

        // Enable mesh visualization - MEMORY SAFE: only use debug wireframe
        // NOTE: receivesLighting causes RAM accumulation, so we only use debugOptions
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

        // Hide ARKit's mesh for preview mode (preview has its own background)
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

        // Restore ARKit's mesh visualization (debug wireframe only - no receivesLighting for memory safety)
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

        // Reset memory state
        memoryPressureLevel = 0

        sendMeshUpdate()
    }

    @objc public func exportMesh(filename: String, completion: @escaping (String?, Int, Int, String?) -> Void) {
        // Use disk storage for complete export (includes evicted anchors)
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
            "isScanning": isScanning,
            "memoryPressure": memoryPressureLevel
        ]
    }

    // MARK: - Memory Management Methods

    /// Get current memory usage in MB
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size / (1024 * 1024) : 0
    }

    /// Check memory pressure and log warnings
    private func checkMemoryPressure() {
        let now = Date()
        guard now.timeIntervalSince(lastMemoryCheckTime) >= memoryCheckInterval else { return }
        lastMemoryCheckTime = now

        let currentUsage = getCurrentMemoryUsage()

        // Determine pressure level
        let previousLevel = memoryPressureLevel
        if currentUsage >= memoryCriticalThreshold {
            memoryPressureLevel = 2  // Critical
        } else if currentUsage >= memoryWarningThreshold {
            memoryPressureLevel = 1  // Warning
        } else {
            memoryPressureLevel = 0
        }

        // Log warnings on level change
        if memoryPressureLevel >= 2 && previousLevel < 2 {
            print("⚠️ Memory CRITICAL: \(currentUsage)MB")
        } else if memoryPressureLevel >= 1 && previousLevel < 1 {
            print("⚠️ Memory WARNING: \(currentUsage)MB")
        }
    }

    // MARK: - Private Methods

    /// Update mesh visibility using ARKit's debug options
    /// MEMORY SAFE: Only uses debugOptions, no receivesLighting (causes RAM accumulation)
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

}

// MARK: - ARSessionDelegate
// MEMORY-EFFICIENT: Uses ARKit's built-in visualization, only stores to disk for export

extension ARKitMeshScannerView: ARSessionDelegate {

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Check memory pressure periodically
        checkMemoryPressure()
    }

    /// Handle new mesh anchors: store to disk only (ARKit handles visualization via debugOptions)
    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Store to disk for export - ARKit's debugOptions handles visualization
                diskMeshStorage.storeAnchor(meshAnchor)
            }
        }
        throttledSendUpdate()
    }

    /// Handle updated mesh anchors: update disk storage only
    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }

        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Update disk storage - ARKit's debugOptions handles visualization
                diskMeshStorage.storeAnchor(meshAnchor)
            }
        }
        throttledSendUpdate()
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Remove from disk storage - ARKit handles removing visualization
                diskMeshStorage.removeAnchor(meshAnchor.identifier)
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
