//
//  MeshExporter.swift
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
import ARKit
import simd

/// Result of a mesh export operation.
struct MeshExportResult {
    let path: String
    let vertexCount: Int
    let faceCount: Int
}

/// Handles exporting mesh data to OBJ format.
final class MeshExporter {

    // MARK: - Memory Monitoring

    /// Returns current memory usage in MB for debugging
    private func getMemoryUsageMB() -> UInt64 {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return taskInfo.resident_size / 1_000_000
        }
        return 0
    }

    // MARK: - Public Methods

    /// Exports mesh anchors to an OBJ file.
    /// - Parameters:
    ///   - meshAnchors: Dictionary of mesh anchors to export
    ///   - filename: Base filename (without extension)
    ///   - capturedFrames: Captured frames (reserved for future texture support)
    ///   - quality: Export quality level (affects file size)
    ///   - completion: Callback with export result or error
    func exportMesh(
        meshAnchors: [UUID: ARMeshAnchor],
        filename: String,
        capturedFrames: [CapturedFrame],
        quality: MeshQuality = .high,
        completion: @escaping (Result<MeshExportResult, Error>) -> Void
    ) {
        guard !meshAnchors.isEmpty else {
            completion(.failure(MeshExportError.noMeshData))
            return
        }

        // Log memory usage before export for debugging crashes
        let memoryMB = getMemoryUsageMB()
        print("📊 Starting mesh export - Memory usage: \(memoryMB)MB, Anchors: \(meshAnchors.count)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let result = try self.performExport(
                    meshAnchors: meshAnchors,
                    filename: filename,
                    quality: quality
                )
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Exports merged mesh from chunk files plus current anchors.
    func exportMergedMesh(
        chunkPaths: [String],
        currentAnchors: [UUID: ARMeshAnchor],
        filename: String,
        capturedFrames: [CapturedFrame],
        quality: MeshQuality = .high,
        completion: @escaping (Result<MeshExportResult, Error>) -> Void
    ) {
        let memoryMB = getMemoryUsageMB()
        print("📊 Starting merged export - Memory: \(memoryMB)MB, Chunks: \(chunkPaths.count), Anchors: \(currentAnchors.count)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let result = try self.performMergedExport(
                    chunkPaths: chunkPaths,
                    currentAnchors: currentAnchors,
                    filename: filename,
                    quality: quality
                )
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Private Methods

    private func performMergedExport(
        chunkPaths: [String],
        currentAnchors: [UUID: ARMeshAnchor],
        filename: String,
        quality: MeshQuality
    ) throws -> MeshExportResult {

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[Int]] = []
        var vertexOffset = 0

        // 1. Load vertices/faces from each chunk file
        for (index, chunkPath) in chunkPaths.enumerated() {
            print("📖 Loading chunk \(index + 1)/\(chunkPaths.count)...")
            if let parsed = parseOBJFile(path: chunkPath) {
                let offsetFaces = parsed.faces.map { $0.map { $0 + vertexOffset } }
                allVertices.append(contentsOf: parsed.vertices)
                allNormals.append(contentsOf: parsed.normals)
                allFaces.append(contentsOf: offsetFaces)
                vertexOffset += parsed.vertices.count
                print("  ✓ Loaded \(parsed.vertices.count) vertices, \(parsed.faces.count) faces")
            } else {
                print("  ⚠️ Failed to parse chunk: \(chunkPath)")
            }
        }

        // 2. Add current in-memory anchors
        print("📖 Processing \(currentAnchors.count) current anchors...")
        for (_, anchor) in currentAnchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces

            // Transform vertices to world coordinates
            let vertexBuffer = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let vertexPointer = vertexBuffer.advanced(by: vertices.offset + vertices.stride * i)
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldVertex = anchor.transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                allVertices.append(SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z))
            }

            // Get normals
            if geometry.normals.count > 0 {
                let normalBuffer = geometry.normals.buffer.contents()
                let normalMatrix = simd_float3x3(
                    simd_float3(anchor.transform.columns.0.x, anchor.transform.columns.0.y, anchor.transform.columns.0.z),
                    simd_float3(anchor.transform.columns.1.x, anchor.transform.columns.1.y, anchor.transform.columns.1.z),
                    simd_float3(anchor.transform.columns.2.x, anchor.transform.columns.2.y, anchor.transform.columns.2.z)
                )
                for i in 0..<geometry.normals.count {
                    let normalPointer = normalBuffer.advanced(by: geometry.normals.offset + geometry.normals.stride * i)
                    let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    allNormals.append(normalize(normalMatrix * normal))
                }
            }

            // Get faces
            let faceBuffer = faces.buffer.contents()
            for i in 0..<faces.count {
                let facePointer = faceBuffer.advanced(by: faces.bytesPerIndex * faces.indexCountPerPrimitive * i)
                var faceIndices: [Int] = []
                for j in 0..<faces.indexCountPerPrimitive {
                    let indexPointer = facePointer.advanced(by: faces.bytesPerIndex * j)
                    let index: Int
                    if faces.bytesPerIndex == 4 {
                        index = Int(indexPointer.assumingMemoryBound(to: UInt32.self).pointee)
                    } else {
                        index = Int(indexPointer.assumingMemoryBound(to: UInt16.self).pointee)
                    }
                    faceIndices.append(index + vertexOffset)
                }
                allFaces.append(faceIndices)
            }
            vertexOffset += vertices.count
        }

        guard !allVertices.isEmpty else {
            throw MeshExportError.noMeshData
        }

        print("📊 Total before decimation: \(allVertices.count) vertices, \(allFaces.count) faces")

        // 3. Apply decimation to reduce file size
        let decimated = MeshDecimator.decimate(
            vertices: allVertices,
            normals: allNormals,
            faces: allFaces,
            quality: quality
        )

        let finalVertices = decimated.vertices
        let finalNormals = decimated.normals
        let finalFaces = decimated.faces

        print("📊 After decimation: \(finalVertices.count) vertices, \(finalFaces.count) faces")

        // 4. Write merged OBJ file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let objPath = documentsPath.appendingPathComponent("\(filename).obj")

        var objContent = "# Exported by react-native-arkit-mesh-scanner (merged)\n"
        objContent += "# Chunks merged: \(chunkPaths.count)\n"
        objContent += "# Quality: \(quality.rawValue)\n"
        objContent += "# Vertices: \(finalVertices.count)\n"
        objContent += "# Faces: \(finalFaces.count)\n\n"

        // Vertices
        for vertex in finalVertices {
            objContent += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
        }
        objContent += "\n"

        // Normals
        for normal in finalNormals {
            objContent += "vn \(normal.x) \(normal.y) \(normal.z)\n"
        }
        objContent += "\n"

        // Faces
        let hasNormals = !finalNormals.isEmpty && finalNormals.count == finalVertices.count

        for face in finalFaces {
            if hasNormals {
                let faceStr = face.map { "\($0 + 1)//\($0 + 1)" }.joined(separator: " ")
                objContent += "f \(faceStr)\n"
            } else {
                let faceStr = face.map { String($0 + 1) }.joined(separator: " ")
                objContent += "f \(faceStr)\n"
            }
        }

        do {
            try objContent.write(to: objPath, atomically: true, encoding: .utf8)
        } catch {
            throw MeshExportError.writeFailed(error.localizedDescription)
        }

        print("✅ Merged mesh exported to: \(objPath.path)")

        return MeshExportResult(
            path: objPath.path,
            vertexCount: finalVertices.count,
            faceCount: finalFaces.count
        )
    }

    /// Parse an OBJ file to extract vertices, normals, and faces
    private func parseOBJFile(path: String) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[Int]])? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[Int]] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            guard !parts.isEmpty else { continue }

            switch parts[0] {
            case "v" where parts.count >= 4:
                // Vertex: v x y z
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    vertices.append(SIMD3<Float>(x, y, z))
                }

            case "vn" where parts.count >= 4:
                // Normal: vn x y z
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    normals.append(SIMD3<Float>(x, y, z))
                }

            case "f" where parts.count >= 4:
                // Face: f v1 v2 v3 or f v1//vn1 v2//vn2 v3//vn3
                var faceIndices: [Int] = []
                for i in 1..<parts.count {
                    // Handle formats: "1", "1/2", "1//3", "1/2/3"
                    let vertexPart = parts[i].components(separatedBy: "/").first ?? parts[i]
                    if let index = Int(vertexPart) {
                        // OBJ indices are 1-based, convert to 0-based
                        faceIndices.append(index - 1)
                    }
                }
                if faceIndices.count >= 3 {
                    faces.append(faceIndices)
                }

            default:
                break
            }
        }

        return (vertices, normals, faces)
    }

    private func performExport(
        meshAnchors: [UUID: ARMeshAnchor],
        filename: String,
        quality: MeshQuality
    ) throws -> MeshExportResult {

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[Int]] = []
        var vertexOffset = 0

        for (_, anchor) in meshAnchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces

            // Transform vertices to world coordinates
            let vertexBuffer = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let vertexPointer = vertexBuffer.advanced(by: vertices.offset + vertices.stride * i)
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldVertex = anchor.transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                allVertices.append(SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z))
            }

            // Get normals
            if geometry.normals.count > 0 {
                let normalBuffer = geometry.normals.buffer.contents()
                let normalMatrix = simd_float3x3(
                    simd_float3(anchor.transform.columns.0.x, anchor.transform.columns.0.y, anchor.transform.columns.0.z),
                    simd_float3(anchor.transform.columns.1.x, anchor.transform.columns.1.y, anchor.transform.columns.1.z),
                    simd_float3(anchor.transform.columns.2.x, anchor.transform.columns.2.y, anchor.transform.columns.2.z)
                )
                for i in 0..<geometry.normals.count {
                    let normalPointer = normalBuffer.advanced(by: geometry.normals.offset + geometry.normals.stride * i)
                    let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    allNormals.append(normalize(normalMatrix * normal))
                }
            }

            // Get faces
            let faceBuffer = faces.buffer.contents()
            for i in 0..<faces.count {
                let facePointer = faceBuffer.advanced(by: faces.bytesPerIndex * faces.indexCountPerPrimitive * i)
                var faceIndices: [Int] = []
                for j in 0..<faces.indexCountPerPrimitive {
                    let indexPointer = facePointer.advanced(by: faces.bytesPerIndex * j)
                    let index: Int
                    if faces.bytesPerIndex == 4 {
                        index = Int(indexPointer.assumingMemoryBound(to: UInt32.self).pointee)
                    } else {
                        index = Int(indexPointer.assumingMemoryBound(to: UInt16.self).pointee)
                    }
                    faceIndices.append(index + vertexOffset)
                }
                allFaces.append(faceIndices)
            }
            vertexOffset += vertices.count
        }

        // Apply decimation to reduce file size
        let decimated = MeshDecimator.decimate(
            vertices: allVertices,
            normals: allNormals,
            faces: allFaces,
            quality: quality
        )

        let finalVertices = decimated.vertices
        let finalNormals = decimated.normals
        let finalFaces = decimated.faces

        // Write OBJ file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let objPath = documentsPath.appendingPathComponent("\(filename).obj")

        var objContent = "# Exported by react-native-arkit-mesh-scanner\n"
        objContent += "# Quality: \(quality.rawValue)\n"
        objContent += "# Vertices: \(finalVertices.count)\n"
        objContent += "# Faces: \(finalFaces.count)\n\n"

        // Vertices
        for vertex in finalVertices {
            objContent += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
        }
        objContent += "\n"

        // Normals
        for normal in finalNormals {
            objContent += "vn \(normal.x) \(normal.y) \(normal.z)\n"
        }
        objContent += "\n"

        // Faces
        let hasNormals = !finalNormals.isEmpty && finalNormals.count == finalVertices.count

        for face in finalFaces {
            if hasNormals {
                // f v//vn format
                let faceStr = face.map { "\($0 + 1)//\($0 + 1)" }.joined(separator: " ")
                objContent += "f \(faceStr)\n"
            } else {
                // f v format
                let faceStr = face.map { String($0 + 1) }.joined(separator: " ")
                objContent += "f \(faceStr)\n"
            }
        }

        do {
            try objContent.write(to: objPath, atomically: true, encoding: .utf8)
        } catch {
            throw MeshExportError.writeFailed(error.localizedDescription)
        }

        print("✅ Mesh exported to: \(objPath.path) (quality: \(quality.rawValue))")

        return MeshExportResult(
            path: objPath.path,
            vertexCount: finalVertices.count,
            faceCount: finalFaces.count
        )
    }
}

// MARK: - Errors

enum MeshExportError: LocalizedError {
    case noMeshData
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMeshData:
            return "No mesh data available for export"
        case .writeFailed(let reason):
            return "Failed to write mesh file: \(reason)"
        }
    }
}
