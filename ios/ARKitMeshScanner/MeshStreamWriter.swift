//
//  MeshStreamWriter.swift
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
//  Streams mesh data directly to disk to avoid RAM usage
//

import Foundation
import ARKit

/// Streams mesh data directly to disk without keeping it in RAM
class MeshStreamWriter {
    private let vertexFileURL: URL
    private let faceFileURL: URL
    private var vertexFileHandle: FileHandle?
    private var faceFileHandle: FileHandle?

    private var totalVertexCount: Int = 0
    private var totalFaceCount: Int = 0
    private var anchorVertexCounts: [UUID: Int] = [:] // Track vertex count per anchor for face indexing
    private var anchorVertexOffsets: [UUID: Int] = [:] // Track global vertex offset per anchor

    private let writeQueue = DispatchQueue(label: "mesh.stream.writer", qos: .userInitiated)

    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        vertexFileURL = documentsPath.appendingPathComponent("mesh_stream_\(timestamp)_vertices.tmp")
        faceFileURL = documentsPath.appendingPathComponent("mesh_stream_\(timestamp)_faces.tmp")
    }

    func startWriting() {
        // Create empty files
        FileManager.default.createFile(atPath: vertexFileURL.path, contents: nil)
        FileManager.default.createFile(atPath: faceFileURL.path, contents: nil)

        vertexFileHandle = FileHandle(forWritingAtPath: vertexFileURL.path)
        faceFileHandle = FileHandle(forWritingAtPath: faceFileURL.path)

        totalVertexCount = 0
        totalFaceCount = 0
        anchorVertexCounts.removeAll()
        anchorVertexOffsets.removeAll()
    }

    func stopWriting() {
        vertexFileHandle?.closeFile()
        faceFileHandle?.closeFile()
        vertexFileHandle = nil
        faceFileHandle = nil
    }

    /// Write mesh anchor data to disk immediately
    /// CRITICAL: Copy all buffer data BEFORE dispatching to background queue
    func writeAnchor(_ anchor: ARMeshAnchor) {
        // Extract all data on main thread BEFORE ARKit can invalidate buffers
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        let vertexCount = vertices.count
        let faceCount = faces.count
        let anchorId = anchor.identifier
        let transform = anchor.transform

        guard vertexCount > 0 else { return }

        // Copy vertex buffer immediately
        let vertexStride = vertices.stride
        let bufferOffset = vertices.offset
        let vertexBufferSize = bufferOffset + (vertexStride * vertexCount)

        let vertexDataCopy = UnsafeMutableRawPointer.allocate(byteCount: vertexBufferSize, alignment: 16)
        memcpy(vertexDataCopy, vertices.buffer.contents(), vertexBufferSize)

        // Copy face buffer if exists
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

        // Now dispatch to background with our safe copies
        writeQueue.async { [weak self] in
            defer {
                vertexDataCopy.deallocate()
                faceDataCopy?.deallocate()
            }

            self?.performWrite(
                anchorId: anchorId,
                transform: transform,
                vertexDataCopy: vertexDataCopy,
                vertexCount: vertexCount,
                vertexStride: vertexStride,
                bufferOffset: bufferOffset,
                faceDataCopy: faceDataCopy,
                faceCount: faceCount,
                bytesPerIndex: bytesPerIndex,
                indexCountPerPrimitive: indexCountPerPrimitive
            )
        }
    }

    private func performWrite(
        anchorId: UUID,
        transform: simd_float4x4,
        vertexDataCopy: UnsafeMutableRawPointer,
        vertexCount: Int,
        vertexStride: Int,
        bufferOffset: Int,
        faceDataCopy: UnsafeMutableRawPointer?,
        faceCount: Int,
        bytesPerIndex: Int,
        indexCountPerPrimitive: Int
    ) {
        guard let vertexHandle = vertexFileHandle,
              let faceHandle = faceFileHandle else { return }

        autoreleasepool {
            // Calculate offset for this anchor
            let vertexOffset = totalVertexCount
            anchorVertexOffsets[anchorId] = vertexOffset
            anchorVertexCounts[anchorId] = vertexCount

            // Write vertices
            var vertexChunk = ""
            vertexChunk.reserveCapacity(32768)

            for i in 0..<vertexCount {
                let ptr = vertexDataCopy.advanced(by: bufferOffset + vertexStride * i)
                let vertex = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                vertexChunk += "v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)\n"

                if i % 500 == 499 {
                    if let data = vertexChunk.data(using: .utf8) {
                        vertexHandle.write(data)
                    }
                    vertexChunk = ""
                    vertexChunk.reserveCapacity(32768)
                }
            }
            if !vertexChunk.isEmpty, let data = vertexChunk.data(using: .utf8) {
                vertexHandle.write(data)
            }

            totalVertexCount += vertexCount

            // Write faces if any
            guard faceCount > 0, let faceData = faceDataCopy else { return }

            var faceChunk = ""
            faceChunk.reserveCapacity(32768)

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
                    indices.append(index + vertexOffset + 1) // OBJ is 1-indexed
                }

                let faceStr = indices.map { String($0) }.joined(separator: " ")
                faceChunk += "f \(faceStr)\n"

                if i % 500 == 499 {
                    if let data = faceChunk.data(using: .utf8) {
                        faceHandle.write(data)
                    }
                    faceChunk = ""
                    faceChunk.reserveCapacity(32768)
                }
            }
            if !faceChunk.isEmpty, let data = faceChunk.data(using: .utf8) {
                faceHandle.write(data)
            }

            totalFaceCount += faceCount
        }
    }

    /// Finalize and combine into final OBJ file
    func finalizeToOBJ(filename: String) -> (path: String, vertexCount: Int, faceCount: Int)? {
        stopWriting()

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let objPath = documentsPath.appendingPathComponent("\(filename).obj")

        // Create final file
        FileManager.default.createFile(atPath: objPath.path, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: objPath.path) else { return nil }
        defer { outputHandle.closeFile() }

        // Write header
        let header = "# Exported by react-native-arkit-mesh-scanner\n# Streamed mesh data\n\n"
        outputHandle.write(header.data(using: .utf8)!)

        // Copy vertices
        if let vertexData = try? Data(contentsOf: vertexFileURL) {
            outputHandle.write(vertexData)
        }

        outputHandle.write("\n".data(using: .utf8)!)

        // Copy faces
        if let faceData = try? Data(contentsOf: faceFileURL) {
            outputHandle.write(faceData)
        }

        // Cleanup temp files
        try? FileManager.default.removeItem(at: vertexFileURL)
        try? FileManager.default.removeItem(at: faceFileURL)

        return (objPath.path, totalVertexCount, totalFaceCount)
    }

    /// Get current stats
    func getStats() -> (vertexCount: Int, faceCount: Int, anchorCount: Int) {
        return (totalVertexCount, totalFaceCount, anchorVertexCounts.count)
    }

    /// Cleanup temp files
    func cleanup() {
        stopWriting()
        try? FileManager.default.removeItem(at: vertexFileURL)
        try? FileManager.default.removeItem(at: faceFileURL)
        totalVertexCount = 0
        totalFaceCount = 0
        anchorVertexCounts.removeAll()
        anchorVertexOffsets.removeAll()
    }
}
