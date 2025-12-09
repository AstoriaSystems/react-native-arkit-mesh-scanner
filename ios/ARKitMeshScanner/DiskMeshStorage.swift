//
//  DiskMeshStorage.swift
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
//
//  Memory-safe mesh storage: each anchor gets its own file on disk.
//  Updates REPLACE the file (no duplicates). Export merges all files.
//

import Foundation
import ARKit

/// Stores mesh data on disk with one file per anchor.
/// Thread-safe and memory-efficient for huge scans.
final class DiskMeshStorage {

    private let storageDir: URL
    private let writeQueue = DispatchQueue(label: "mesh.disk.storage", qos: .userInitiated)

    // Track anchor metadata (small - stays in RAM)
    private var anchorMetadata: [UUID: AnchorMeta] = [:]
    private let metadataLock = NSLock()

    // Flag to skip writes after clear (atomic for thread safety)
    private var isCleared: Bool = false

    struct AnchorMeta {
        let vertexCount: Int
        let faceCount: Int
        let filePath: URL
    }

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        storageDir = cacheDir.appendingPathComponent("mesh_anchors_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    /// Store anchor data to disk. Replaces existing file for same anchor (no duplicates).
    /// CRITICAL: Copy buffer data BEFORE calling this from ARKit delegate.
    func storeAnchor(_ anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        let vertexCount = vertices.count
        let faceCount = faces.count
        let anchorId = anchor.identifier
        let transform = anchor.transform

        guard vertexCount > 0 else { return }

        // Copy buffers on main thread BEFORE ARKit invalidates them
        let vertexStride = vertices.stride
        let vertexOffset = vertices.offset
        let vertexBufferSize = vertexOffset + (vertexStride * vertexCount)

        let vertexDataCopy = UnsafeMutableRawPointer.allocate(byteCount: vertexBufferSize, alignment: 16)
        memcpy(vertexDataCopy, vertices.buffer.contents(), vertexBufferSize)

        var faceDataCopy: UnsafeMutableRawPointer? = nil
        var bytesPerIndex = 0
        var indexCountPerPrimitive = 0

        if faceCount > 0 {
            bytesPerIndex = faces.bytesPerIndex
            indexCountPerPrimitive = faces.indexCountPerPrimitive
            let faceBufferSize = bytesPerIndex * indexCountPerPrimitive * faceCount
            faceDataCopy = UnsafeMutableRawPointer.allocate(byteCount: faceBufferSize, alignment: 16)
            memcpy(faceDataCopy!, faces.buffer.contents(), faceBufferSize)
        }

        // Write to disk on background queue
        writeQueue.async { [weak self] in
            defer {
                vertexDataCopy.deallocate()
                faceDataCopy?.deallocate()
            }

            // Skip if storage was cleared while write was queued
            guard let self = self, !self.isCleared else { return }

            self.writeAnchorToDisk(
                anchorId: anchorId,
                transform: transform,
                vertexDataCopy: vertexDataCopy,
                vertexCount: vertexCount,
                vertexStride: vertexStride,
                vertexOffset: vertexOffset,
                faceDataCopy: faceDataCopy,
                faceCount: faceCount,
                bytesPerIndex: bytesPerIndex,
                indexCountPerPrimitive: indexCountPerPrimitive
            )
        }
    }

    private func writeAnchorToDisk(
        anchorId: UUID,
        transform: simd_float4x4,
        vertexDataCopy: UnsafeMutableRawPointer,
        vertexCount: Int,
        vertexStride: Int,
        vertexOffset: Int,
        faceDataCopy: UnsafeMutableRawPointer?,
        faceCount: Int,
        bytesPerIndex: Int,
        indexCountPerPrimitive: Int
    ) {
        autoreleasepool {
            let filePath = storageDir.appendingPathComponent("\(anchorId.uuidString).mesh")

            // Build OBJ content for this anchor
            var content = ""
            content.reserveCapacity(vertexCount * 40 + faceCount * 30)

            // Write vertices
            for i in 0..<vertexCount {
                let ptr = vertexDataCopy.advanced(by: vertexOffset + vertexStride * i)
                let vertex = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                content += "v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)\n"
            }

            // Write faces (local indices, will be adjusted at export)
            if faceCount > 0, let faceData = faceDataCopy {
                for i in 0..<faceCount {
                    var indices = [Int]()
                    for j in 0..<indexCountPerPrimitive {
                        let offset = bytesPerIndex * (i * indexCountPerPrimitive + j)
                        let index: Int
                        if bytesPerIndex == 4 {
                            index = Int(faceData.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
                        } else {
                            index = Int(faceData.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                        }
                        indices.append(index + 1) // OBJ is 1-indexed (local to this anchor)
                    }
                    content += "f \(indices.map { String($0) }.joined(separator: " "))\n"
                }
            }

            // Write to file (overwrites existing - no duplicates!)
            try? content.write(to: filePath, atomically: true, encoding: .utf8)

            // Update metadata
            metadataLock.lock()
            anchorMetadata[anchorId] = AnchorMeta(
                vertexCount: vertexCount,
                faceCount: faceCount,
                filePath: filePath
            )
            metadataLock.unlock()
        }
    }

    /// Remove anchor from storage
    func removeAnchor(_ anchorId: UUID) {
        metadataLock.lock()
        if let meta = anchorMetadata.removeValue(forKey: anchorId) {
            metadataLock.unlock()
            writeQueue.async {
                try? FileManager.default.removeItem(at: meta.filePath)
            }
        } else {
            metadataLock.unlock()
        }
    }

    /// Get current stats (from metadata, no disk read)
    func getStats() -> (anchorCount: Int, vertexCount: Int, faceCount: Int) {
        metadataLock.lock()
        defer { metadataLock.unlock() }

        var totalVertices = 0
        var totalFaces = 0
        for (_, meta) in anchorMetadata {
            totalVertices += meta.vertexCount
            totalFaces += meta.faceCount
        }
        return (anchorMetadata.count, totalVertices, totalFaces)
    }

    /// Export all anchors to single OBJ file
    func exportToOBJ(filename: String, completion: @escaping (Result<(path: String, vertexCount: Int, faceCount: Int), Error>) -> Void) {
        writeQueue.async { [weak self] in
            guard let self = self else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage deallocated"])))
                return
            }

            self.metadataLock.lock()
            let anchors = Array(self.anchorMetadata.values).sorted { $0.filePath.lastPathComponent < $1.filePath.lastPathComponent }
            self.metadataLock.unlock()

            guard !anchors.isEmpty else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mesh data"])))
                return
            }

            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let objPath = documentsPath.appendingPathComponent("\(filename).obj")

                FileManager.default.createFile(atPath: objPath.path, contents: nil)
                guard let outputHandle = FileHandle(forWritingAtPath: objPath.path) else {
                    throw NSError(domain: "DiskMeshStorage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot create output file"])
                }
                defer { outputHandle.closeFile() }

                // Write header
                let header = "# Exported by react-native-arkit-mesh-scanner\n# Memory-safe disk storage\n\n"
                outputHandle.write(header.data(using: .utf8)!)

                var totalVertexCount = 0
                var totalFaceCount = 0
                var globalVertexOffset = 0

                // First pass: write all vertices
                for meta in anchors {
                    autoreleasepool {
                        if let content = try? String(contentsOf: meta.filePath, encoding: .utf8) {
                            let lines = content.components(separatedBy: "\n")
                            for line in lines {
                                if line.hasPrefix("v ") {
                                    outputHandle.write((line + "\n").data(using: .utf8)!)
                                    totalVertexCount += 1
                                }
                            }
                        }
                    }
                }

                outputHandle.write("\n".data(using: .utf8)!)

                // Second pass: write all faces with adjusted indices
                for meta in anchors {
                    autoreleasepool {
                        if let content = try? String(contentsOf: meta.filePath, encoding: .utf8) {
                            let lines = content.components(separatedBy: "\n")
                            for line in lines {
                                if line.hasPrefix("f ") {
                                    // Adjust face indices by global offset
                                    let parts = line.dropFirst(2).split(separator: " ")
                                    let adjustedIndices = parts.compactMap { Int($0) }.map { $0 + globalVertexOffset }
                                    let adjustedLine = "f " + adjustedIndices.map { String($0) }.joined(separator: " ")
                                    outputHandle.write((adjustedLine + "\n").data(using: .utf8)!)
                                    totalFaceCount += 1
                                }
                            }
                        }
                        globalVertexOffset += meta.vertexCount
                    }
                }

                DispatchQueue.main.async {
                    completion(.success((objPath.path, totalVertexCount, totalFaceCount)))
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Load all mesh data for preview (vertices and faces as arrays)
    /// Returns nil if no data or error
    func loadAllMeshData(completion: @escaping (Result<(vertices: [SIMD3<Float>], faces: [[Int]]), Error>) -> Void) {
        writeQueue.async { [weak self] in
            guard let self = self else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage deallocated"])))
                return
            }

            self.metadataLock.lock()
            let anchors = Array(self.anchorMetadata.values).sorted { $0.filePath.lastPathComponent < $1.filePath.lastPathComponent }
            self.metadataLock.unlock()

            guard !anchors.isEmpty else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mesh data"])))
                return
            }

            var allVertices: [SIMD3<Float>] = []
            var allFaces: [[Int]] = []
            var globalVertexOffset = 0

            for meta in anchors {
                autoreleasepool {
                    if let content = try? String(contentsOf: meta.filePath, encoding: .utf8) {
                        let lines = content.components(separatedBy: "\n")
                        var localVertexCount = 0

                        // Parse vertices
                        for line in lines {
                            if line.hasPrefix("v ") {
                                let parts = line.dropFirst(2).split(separator: " ")
                                if parts.count >= 3,
                                   let x = Float(parts[0]),
                                   let y = Float(parts[1]),
                                   let z = Float(parts[2]) {
                                    allVertices.append(SIMD3<Float>(x, y, z))
                                    localVertexCount += 1
                                }
                            }
                        }

                        // Parse faces with offset adjustment
                        for line in lines {
                            if line.hasPrefix("f ") {
                                let parts = line.dropFirst(2).split(separator: " ")
                                let indices = parts.compactMap { Int($0) }.map { $0 - 1 + globalVertexOffset } // Convert to 0-indexed with offset
                                if indices.count >= 3 {
                                    allFaces.append(indices)
                                }
                            }
                        }

                        globalVertexOffset += localVertexCount
                    }
                }
            }

            DispatchQueue.main.async {
                completion(.success((allVertices, allFaces)))
            }
        }
    }

    /// Clear all stored data - thread safe
    func clear() {
        // Set flag first to stop accepting new writes
        isCleared = true

        // Clear metadata
        metadataLock.lock()
        anchorMetadata.removeAll()
        metadataLock.unlock()

        // Queue cleanup after all pending writes complete
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.storageDir)
            try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
            // Reset flag after cleanup so new scans can start
            self.isCleared = false
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: storageDir)
    }
}
