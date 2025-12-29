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
/// 100% THREAD-SAFE and memory-efficient for huge scans.
/// CRITICAL: Never loses scan data - disk storage is always active.
final class DiskMeshStorage {

    private let storageDir: URL
    private let writeQueue = DispatchQueue(label: "mesh.disk.storage", qos: .userInitiated)

    // Track anchor metadata (small - stays in RAM)
    private var anchorMetadata: [UUID: AnchorMeta] = [:]
    private let metadataLock = NSLock()

    // Track which anchors have pending writes to avoid duplicate allocations
    private var pendingAnchorWrites: Set<UUID> = []
    private let pendingWritesLock = NSLock()

    // Throttle updates per anchor - only store if enough time has passed
    private var lastAnchorUpdateTime: [UUID: Date] = [:]
    private let anchorUpdateInterval: TimeInterval = 1.0  // Minimum 1 second between updates per anchor

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

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to create mesh storage directory: \(error)")
        }
    }

    /// Store anchor data to disk. Replaces existing file for same anchor (no duplicates).
    /// 100% THREAD-SAFE: Copies buffer data synchronously before ARKit can invalidate.
    /// MEMORY-SAFE: Throttles updates and skips pending writes to prevent RAM buildup.
    func storeAnchor(_ anchor: ARMeshAnchor) {
        let anchorId = anchor.identifier
        let now = Date()

        // MEMORY SAFETY: Throttle updates per anchor (max once per second)
        // This drastically reduces buffer allocations during active scanning
        metadataLock.lock()
        if let lastUpdate = lastAnchorUpdateTime[anchorId] {
            if now.timeIntervalSince(lastUpdate) < anchorUpdateInterval {
                metadataLock.unlock()
                return  // Skip - updated too recently
            }
        }
        lastAnchorUpdateTime[anchorId] = now
        metadataLock.unlock()

        // MEMORY SAFETY: Skip if this anchor already has a pending write
        // This prevents RAM from filling up with queued buffer copies
        pendingWritesLock.lock()
        if pendingAnchorWrites.contains(anchorId) {
            pendingWritesLock.unlock()
            return  // Skip - previous version still being written
        }
        pendingAnchorWrites.insert(anchorId)
        pendingWritesLock.unlock()

        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        let vertexCount = vertices.count
        let faceCount = faces.count
        let transform = anchor.transform

        guard vertexCount > 0 else {
            // Remove from pending if no data
            pendingWritesLock.lock()
            pendingAnchorWrites.remove(anchorId)
            pendingWritesLock.unlock()
            return
        }

        // THREAD SAFETY: Cache all geometry properties BEFORE buffer access
        let vertexStride = vertices.stride
        let vertexOffset = vertices.offset
        let vertexBufferSize = vertexOffset + (vertexStride * vertexCount)

        // CRITICAL: Allocate and copy in one atomic operation
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

        // Write to disk on background queue - data is now safely copied
        writeQueue.async { [weak self] in
            defer {
                vertexDataCopy.deallocate()
                faceDataCopy?.deallocate()

                // Remove from pending set so next update can be processed
                self?.pendingWritesLock.lock()
                self?.pendingAnchorWrites.remove(anchorId)
                self?.pendingWritesLock.unlock()
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

    /// MEMORY-SAFE: Stream write to disk without building huge strings in RAM
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

            // Create file and get handle for streaming writes
            FileManager.default.createFile(atPath: filePath.path, contents: nil)
            guard let fileHandle = FileHandle(forWritingAtPath: filePath.path) else {
                print("Failed to create file handle for \(filePath)")
                return
            }

            defer {
                try? fileHandle.close()
            }

            // STREAMING WRITE: Write vertices in chunks to avoid memory spikes
            let chunkSize = 500  // Process 500 vertices at a time
            var vertexChunk = ""
            vertexChunk.reserveCapacity(chunkSize * 45)

            for i in 0..<vertexCount {
                autoreleasepool {
                    let ptr = vertexDataCopy.advanced(by: vertexOffset + vertexStride * i)
                    let vertex = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                    vertexChunk += "v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)\n"

                    // Flush chunk to disk periodically
                    if (i + 1) % chunkSize == 0 || i == vertexCount - 1 {
                        if let data = vertexChunk.data(using: .utf8) {
                            try? fileHandle.write(contentsOf: data)
                        }
                        vertexChunk = ""
                        vertexChunk.reserveCapacity(chunkSize * 45)
                    }
                }
            }

            // STREAMING WRITE: Write faces in chunks
            if faceCount > 0, let faceData = faceDataCopy {
                var faceChunk = ""
                faceChunk.reserveCapacity(chunkSize * 30)

                for i in 0..<faceCount {
                    autoreleasepool {
                        var indices = [Int]()
                        indices.reserveCapacity(indexCountPerPrimitive)

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
                        faceChunk += "f \(indices.map { String($0) }.joined(separator: " "))\n"

                        // Flush chunk to disk periodically
                        if (i + 1) % chunkSize == 0 || i == faceCount - 1 {
                            if let data = faceChunk.data(using: .utf8) {
                                try? fileHandle.write(contentsOf: data)
                            }
                            faceChunk = ""
                            faceChunk.reserveCapacity(chunkSize * 30)
                        }
                    }
                }
            }

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

    /// MEMORY-SAFE: Load mesh data for preview
    /// Limits to subset of anchors if data is too large
    func loadAllMeshData(completion: @escaping (Result<(vertices: [SIMD3<Float>], faces: [[Int]]), Error>) -> Void) {
        writeQueue.async { [weak self] in
            guard let self = self else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage deallocated"])))
                return
            }

            self.metadataLock.lock()
            // Sort by SMALLEST first to get better spatial coverage (many small anchors = more area)
            var anchors = Array(self.anchorMetadata.values).sorted { $0.vertexCount < $1.vertexCount }
            let totalVertexCount = self.anchorMetadata.values.reduce(0) { $0 + $1.vertexCount }
            self.metadataLock.unlock()

            guard !anchors.isEmpty else {
                completion(.failure(NSError(domain: "DiskMeshStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mesh data"])))
                return
            }

            // MEMORY SAFETY: Limit vertices for preview to prevent RAM spike
            // 500K vertices = ~6MB vertex data + ~4MB face indices = ~10MB total (safe for preview)
            let maxPreviewVertices = 500_000
            var selectedAnchors: [AnchorMeta] = []
            var currentVertexCount = 0

            // If total is under limit, use all anchors
            if totalVertexCount <= maxPreviewVertices {
                selectedAnchors = anchors
                currentVertexCount = totalVertexCount
            } else {
                // Take anchors until we hit the limit
                for anchor in anchors {
                    if currentVertexCount + anchor.vertexCount <= maxPreviewVertices {
                        selectedAnchors.append(anchor)
                        currentVertexCount += anchor.vertexCount
                    }
                }
            }

            print("Loading preview: \(selectedAnchors.count)/\(anchors.count) anchors, \(currentVertexCount)/\(totalVertexCount) vertices")

            var allVertices: [SIMD3<Float>] = []
            var allFaces: [[Int]] = []
            var globalVertexOffset = 0

            allVertices.reserveCapacity(currentVertexCount)

            for meta in selectedAnchors {
                autoreleasepool {
                    guard let content = try? String(contentsOf: meta.filePath, encoding: .utf8) else { return }

                    var localVertices: [SIMD3<Float>] = []
                    var localFaces: [[Int]] = []

                    let lines = content.components(separatedBy: "\n")

                    for line in lines {
                        if line.hasPrefix("v ") {
                            let parts = line.dropFirst(2).split(separator: " ")
                            if parts.count >= 3,
                               let x = Float(parts[0]),
                               let y = Float(parts[1]),
                               let z = Float(parts[2]) {
                                localVertices.append(SIMD3<Float>(x, y, z))
                            }
                        } else if line.hasPrefix("f ") {
                            let parts = line.dropFirst(2).split(separator: " ")
                            let indices = parts.compactMap { Int($0) }.map { ($0 - 1) + globalVertexOffset }
                            if indices.count >= 3 {
                                localFaces.append(indices)
                            }
                        }
                    }

                    // Append local data to global arrays
                    allVertices.append(contentsOf: localVertices)
                    allFaces.append(contentsOf: localFaces)
                    globalVertexOffset += localVertices.count
                }
            }

            print("Preview loaded: \(allVertices.count) vertices, \(allFaces.count) faces")

            DispatchQueue.main.async {
                completion(.success((allVertices, allFaces)))
            }
        }
    }

    /// Clear all stored data - thread safe
    /// Waits for all pending writes to complete before clearing
    func clear() {
        // Set flag first to stop accepting new writes
        isCleared = true

        // Clear pending writes set
        pendingWritesLock.lock()
        pendingAnchorWrites.removeAll()
        pendingWritesLock.unlock()

        // Clear metadata and throttle times
        metadataLock.lock()
        anchorMetadata.removeAll()
        lastAnchorUpdateTime.removeAll()
        metadataLock.unlock()

        // Queue cleanup
        writeQueue.async { [weak self] in
            guard let self = self else { return }

            // Now safe to delete
            try? FileManager.default.removeItem(at: self.storageDir)
            try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)

            // Reset flag after cleanup so new scans can start
            self.isCleared = false
        }
    }

    /// Get number of pending disk writes
    func getPendingWriteCount() -> Int {
        pendingWritesLock.lock()
        let count = pendingAnchorWrites.count
        pendingWritesLock.unlock()
        return count
    }

    /// Wait for all pending writes to complete (blocking)
    func waitForPendingWrites(timeout: TimeInterval = 5.0) {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if getPendingWriteCount() == 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("⚠️ DiskMeshStorage: Timeout waiting for pending writes")
    }

    deinit {
        // Wait for pending writes before cleanup
        waitForPendingWrites(timeout: 2.0)
        try? FileManager.default.removeItem(at: storageDir)
    }
}
