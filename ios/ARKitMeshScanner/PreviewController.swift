//
//  PreviewController.swift
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
import RealityKit
import ARKit
import simd

/// Delegate protocol for preview controller events.
protocol PreviewControllerDelegate: AnyObject {
    func previewControllerDidEnterPreview(_ controller: PreviewController)
    func previewControllerDidExitPreview(_ controller: PreviewController)
}

/// Handles 3D preview mode with gesture-based navigation.
final class PreviewController {

    // MARK: - Properties

    weak var delegate: PreviewControllerDelegate?

    private weak var arView: ARView?

    private var isPreviewMode: Bool = false
    private var previewAnchor: AnchorEntity?
    private var previewModel: ModelEntity?
    private var cameraAnchor: AnchorEntity?

    private var previewRotation: SIMD3<Float> = .zero
    private var previewScale: Float = 1.0
    private var lastPinchScale: Float = 1.0

    // MARK: - Public Methods

    /// Enters preview mode with pre-loaded mesh data from disk storage.
    /// This version loads complete mesh data including evicted anchors.
    func enterPreviewMode(
        arView: ARView,
        vertices: [SIMD3<Float>],
        faces: [[Int]],
        meshColor: String
    ) {
        guard !vertices.isEmpty else { return }

        self.arView = arView
        isPreviewMode = true

        // Pause AR session
        arView.session.pause()

        // Dark background for better contrast
        arView.environment.background = .color(.init(white: 0.05, alpha: 1.0))

        // Reset preview state
        previewRotation = .zero
        previewScale = 1.0

        // Add gesture recognizers
        setupPreviewGestures()

        // Create preview mesh with pre-loaded data
        createPreviewMeshFromData(vertices: vertices, faces: faces, meshColor: meshColor)

        delegate?.previewControllerDidEnterPreview(self)
    }


    /// Exits preview mode and restores the AR view.
    func exitPreviewMode() {
        guard let arView = arView else { return }

        isPreviewMode = false

        // Remove gesture recognizers
        arView.gestureRecognizers?.forEach { arView.removeGestureRecognizer($0) }

        // Remove preview anchor
        if let anchor = previewAnchor {
            arView.scene.removeAnchor(anchor)
            previewAnchor = nil
            previewModel = nil
        }

        // Remove camera anchor
        if let camAnchor = cameraAnchor {
            arView.scene.removeAnchor(camAnchor)
            cameraAnchor = nil
        }

        // Restore camera background
        arView.environment.background = .cameraFeed()

        delegate?.previewControllerDidExitPreview(self)
        self.arView = nil
    }

    var isActive: Bool {
        return isPreviewMode
    }

    // MARK: - Gesture Handling

    private func setupPreviewGestures() {
        guard let arView = arView else { return }

        // Remove existing gesture recognizers
        arView.gestureRecognizers?.forEach { arView.removeGestureRecognizer($0) }

        // Pan for rotation
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        arView.addGestureRecognizer(panGesture)

        // Pinch for zoom
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        arView.addGestureRecognizer(pinchGesture)

        // Double tap to center
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapGesture(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        arView.addGestureRecognizer(doubleTapGesture)
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard isPreviewMode, let arView = arView, previewModel != nil else { return }

        let translation = gesture.translation(in: arView)

        if gesture.state == .changed {
            let sensitivity: Float = 0.005
            previewRotation.y += Float(translation.x) * sensitivity
            previewRotation.x += Float(translation.y) * sensitivity

            // Clamp X rotation to prevent flipping
            previewRotation.x = max(-.pi * 0.4, min(.pi * 0.4, previewRotation.x))

            updatePreviewTransform()
        }

        gesture.setTranslation(.zero, in: arView)
    }

    @objc private func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        guard isPreviewMode else { return }

        if gesture.state == .began {
            lastPinchScale = previewScale
        } else if gesture.state == .changed {
            previewScale = lastPinchScale * Float(gesture.scale)
            previewScale = max(0.3, min(3.0, previewScale))
            updatePreviewTransform()
        }
    }

    @objc private func handleDoubleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard isPreviewMode else { return }

        // Reset to center
        previewRotation = .zero
        previewScale = 1.0
        updatePreviewTransform()
    }

    private func updatePreviewTransform() {
        guard let model = previewModel else { return }

        // Apply rotation - Y first (horizontal), then X (vertical tilt)
        let rotationY = simd_quatf(angle: previewRotation.y, axis: [0, 1, 0])
        let rotationX = simd_quatf(angle: previewRotation.x, axis: [1, 0, 0])
        model.orientation = rotationX * rotationY

        // Apply scale
        model.scale = [previewScale, previewScale, previewScale]
    }

    // MARK: - Mesh Creation with Depth Shading

    /// Create preview mesh from pre-loaded vertex/face data (complete mesh from disk)
    private func createPreviewMeshFromData(vertices: [SIMD3<Float>], faces: [[Int]], meshColor: String) {
        guard let arView = arView else { return }

        // Parse color from hex string (from React Native meshColor prop)
        let previewColor = UIColor(hex: meshColor) ?? UIColor(red: 0.6, green: 0.75, blue: 0.9, alpha: 1.0)

        // Calculate bounding box
        var minBounds = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBounds = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for pos in vertices {
            minBounds = min(minBounds, pos)
            maxBounds = max(maxBounds, pos)
        }

        let center = (minBounds + maxBounds) / 2
        let size = maxBounds - minBounds
        let maxDimension = max(size.x, max(size.y, size.z))
        let normalizedScale: Float = 0.5 / maxDimension

        // Center and scale positions
        var centeredPositions: [SIMD3<Float>] = []
        for pos in vertices {
            centeredPositions.append((pos - center) * normalizedScale)
        }

        // Convert faces to UInt32 indices
        var allIndices: [UInt32] = []
        for face in faces {
            for index in face {
                allIndices.append(UInt32(index))
            }
        }

        // Create mesh descriptor
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(centeredPositions)
        descriptor.primitives = .triangles(allIndices)

        do {
            let meshResource = try MeshResource.generate(from: [descriptor])

            // Preview material - uses meshColor from React Native props
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: previewColor.withAlphaComponent(0.9))
            material.roughness = .init(floatLiteral: 0.7)
            material.metallic = .init(floatLiteral: 0.0)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.9))

            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])

            // Create anchor at world origin
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(modelEntity)

            // Strong directional light from top-front
            let mainLight = DirectionalLight()
            mainLight.light.color = .white
            mainLight.light.intensity = 8000
            mainLight.look(at: [0, 0, 0], from: [0.5, 1.5, 1.0], relativeTo: nil)
            anchor.addChild(mainLight)

            // Fill light from the side
            let fillLight = DirectionalLight()
            fillLight.light.color = UIColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
            fillLight.light.intensity = 3000
            fillLight.look(at: [0, 0, 0], from: [-1.0, 0.5, 0.5], relativeTo: nil)
            anchor.addChild(fillLight)

            // Rim light from behind
            let rimLight = DirectionalLight()
            rimLight.light.color = UIColor(red: 0.9, green: 0.95, blue: 1.0, alpha: 1.0)
            rimLight.light.intensity = 2000
            rimLight.look(at: [0, 0, 0], from: [0, 0.5, -1.5], relativeTo: nil)
            anchor.addChild(rimLight)

            arView.scene.addAnchor(anchor)
            previewAnchor = anchor
            previewModel = modelEntity

            // Setup camera
            setupPreviewCamera()

            // Apply initial transform
            updatePreviewTransform()

            print("Preview mesh created with \(centeredPositions.count) vertices, \(allIndices.count / 3) triangles (from disk)")

        } catch {
            print("Failed to create preview mesh from data: \(error)")
        }
    }

    private func setupPreviewCamera() {
        guard let arView = arView else { return }

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60

        let camAnchor = AnchorEntity(world: .zero)
        camAnchor.addChild(camera)
        camAnchor.position = [0, 0, 1.5]
        camAnchor.look(at: [0, 0, 0], from: camAnchor.position, relativeTo: nil)

        arView.scene.addAnchor(camAnchor)
        cameraAnchor = camAnchor
    }
}
