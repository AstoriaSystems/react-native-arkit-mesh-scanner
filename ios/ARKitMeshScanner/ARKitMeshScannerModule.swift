//
//  ARKitMeshScannerModule.swift
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

@objc(ARKitMeshScannerModule)
class ARKitMeshScannerModule: NSObject {

    @objc var bridge: RCTBridge!

    @objc static func requiresMainQueueSetup() -> Bool {
        return true
    }

    @objc static func moduleName() -> String! {
        return "ARKitMeshScannerModule"
    }

    // MARK: - Exported Methods
    @objc func isLiDARSupported(_ resolve: @escaping RCTPromiseResolveBlock,
                                 rejecter reject: @escaping RCTPromiseRejectBlock) {
        let supported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        resolve(supported)
    }

    @objc func startScanning(_ viewTag: NSNumber) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                return
            }
            view.startScanning()
        }
    }

    @objc func stopScanning(_ viewTag: NSNumber) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                return
            }
            view.stopScanning()
        }
    }

    @objc func clearMesh(_ viewTag: NSNumber) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                return
            }
            view.clearMesh()
        }
    }

    @objc func exportMesh(_ viewTag: NSNumber,
                          filename: String,
                          resolver resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                reject("VIEW_NOT_FOUND", "Could not find ARKitMeshScannerView", nil)
                return
            }

            view.exportMesh(filename: filename) { path, vertexCount, faceCount, error in
                if let error = error {
                    reject("EXPORT_ERROR", error, nil)
                } else if let path = path {
                    resolve([
                        "path": path,
                        "vertexCount": vertexCount,
                        "faceCount": faceCount
                    ])
                }
            }
        }
    }

    @objc func getMeshStats(_ viewTag: NSNumber,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                reject("VIEW_NOT_FOUND", "Could not find ARKitMeshScannerView", nil)
                return
            }

            let stats = view.getMeshStats()
            resolve(stats)
        }
    }

    @objc func enterPreviewMode(_ viewTag: NSNumber) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                return
            }
            view.enterPreviewMode()
        }
    }

    @objc func exitPreviewMode(_ viewTag: NSNumber) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let uiManager = self.bridge.uiManager,
                  let view = uiManager.view(forReactTag: viewTag) as? ARKitMeshScannerView else {
                return
            }
            view.exitPreviewMode()
        }
    }

    @objc func getMemoryUsage(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let usedBytes = UInt64(info.resident_size)
            let usedMB = Int(usedBytes / 1024 / 1024)
            resolve([
                "usedBytes": usedBytes,
                "usedMB": usedMB
            ])
        } else {
            resolve([
                "usedBytes": 0,
                "usedMB": 0
            ])
        }
    }
}
