//
//  MeshDecimator.swift
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


import Foundation
import simd

/// Quality level for mesh decimation.
enum MeshQuality: String {
    case low = "low"           // ~10% of original vertices
    case medium = "medium"     // ~25% of original vertices
    case high = "high"         // ~50% of original vertices
    case full = "full"         // 100% of original vertices

    var gridSize: Float {
        switch self {
        case .low: return 0.05      // 5cm grid
        case .medium: return 0.025  // 2.5cm grid
        case .high: return 0.015    // 1.5cm grid
        case .full: return 0.0      // No decimation
        }
    }
}

/// Result of mesh decimation.
struct DecimatedMesh {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let faces: [[Int]]
}

/// Handles mesh decimation using grid-based vertex clustering.
final class MeshDecimator {

    /// Decimates a mesh by clustering vertices into a 3D grid.
    /// - Parameters:
    ///   - vertices: Input vertex positions
    ///   - normals: Input vertex normals (can be empty)
    ///   - faces: Input face indices
    ///   - quality: Desired quality level
    /// - Returns: Decimated mesh
    static func decimate(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [[Int]],
        quality: MeshQuality
    ) -> DecimatedMesh {
        guard quality != .full else {
            return DecimatedMesh(vertices: vertices, normals: normals, faces: faces)
        }

        guard !vertices.isEmpty else {
            return DecimatedMesh(vertices: [], normals: [], faces: [])
        }

        let gridSize = quality.gridSize

        // Map from grid cell to cluster data
        var clusters: [SIMD3<Int>: VertexCluster] = [:]

        // Map from original vertex index to cluster key
        var vertexToCluster: [Int: SIMD3<Int>] = [:]

        // Cluster vertices into grid cells
        for (index, vertex) in vertices.enumerated() {
            let cellKey = SIMD3<Int>(
                Int(floor(vertex.x / gridSize)),
                Int(floor(vertex.y / gridSize)),
                Int(floor(vertex.z / gridSize))
            )

            vertexToCluster[index] = cellKey

            if clusters[cellKey] == nil {
                clusters[cellKey] = VertexCluster()
            }

            clusters[cellKey]?.addVertex(vertex)

            if !normals.isEmpty && index < normals.count {
                clusters[cellKey]?.addNormal(normals[index])
            }
        }

        // Create new vertices from cluster centroids
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var clusterToNewIndex: [SIMD3<Int>: Int] = [:]

        for (cellKey, cluster) in clusters {
            clusterToNewIndex[cellKey] = newVertices.count
            newVertices.append(cluster.centroid)
            if let normal = cluster.averageNormal {
                newNormals.append(normal)
            }
        }

        // Remap faces to new vertex indices
        var newFaces: [[Int]] = []

        for face in faces {
            var newFace: [Int] = []
            var validFace = true
            var seenIndices = Set<Int>()

            for oldIndex in face {
                guard let cellKey = vertexToCluster[oldIndex],
                      let newIndex = clusterToNewIndex[cellKey] else {
                    validFace = false
                    break
                }

                // Skip degenerate faces (where multiple vertices map to same cluster)
                if seenIndices.contains(newIndex) {
                    validFace = false
                    break
                }
                seenIndices.insert(newIndex)
                newFace.append(newIndex)
            }

            if validFace && newFace.count >= 3 {
                newFaces.append(newFace)
            }
        }

        return DecimatedMesh(
            vertices: newVertices,
            normals: newNormals,
            faces: newFaces
        )
    }
}

// MARK: - Vertex Cluster

private class VertexCluster {
    private var vertices: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []

    var centroid: SIMD3<Float> {
        guard !vertices.isEmpty else { return .zero }
        let sum = vertices.reduce(SIMD3<Float>.zero, +)
        return sum / Float(vertices.count)
    }

    var averageNormal: SIMD3<Float>? {
        guard !normals.isEmpty else { return nil }
        let sum = normals.reduce(SIMD3<Float>.zero, +)
        let avg = sum / Float(normals.count)
        let len = length(avg)
        return len > 0.0001 ? avg / len : nil
    }

    func addVertex(_ vertex: SIMD3<Float>) {
        vertices.append(vertex)
    }

    func addNormal(_ normal: SIMD3<Float>) {
        normals.append(normal)
    }
}

// MARK: - SIMD3<Int> Hashable

extension SIMD3: Hashable where Scalar == Int {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(z)
    }
}
