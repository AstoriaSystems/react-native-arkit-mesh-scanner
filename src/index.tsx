/**
 * react-native-arkit-mesh-scanner
 *
 * Created by Mergim Mavraj on 25.11.2025.
 * Copyright (c) 2025 Astoria Systems GmbH
 * Author: Mergim Mavraj
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import React, {
  forwardRef,
  useImperativeHandle,
  useRef,
  useCallback,
} from 'react';
import {
  requireNativeComponent,
  NativeModules,
  findNodeHandle,
  ViewStyle,
  StyleSheet,
  Platform,
} from 'react-native';

// Types
export interface MeshStats {
  anchorCount: number;
  vertexCount: number;
  faceCount: number;
  isScanning?: boolean;
}

export interface ExportResult {
  path: string;
  vertexCount: number;
  faceCount: number;
}

export interface MemoryUsage {
  usedMB: number;
  usedBytes: number;
}

export interface MeshUpdateEvent {
  nativeEvent: MeshStats;
}

export interface ErrorEvent {
  nativeEvent: {
    message: string;
  };
}

/** Mesh quality levels for export */
export type MeshQuality = 'low' | 'medium' | 'high' | 'full';

export interface ARKitMeshScannerProps {
  style?: ViewStyle;
  /** Show mesh overlay during scanning (default: true) */
  showMesh?: boolean;
  /** Mesh color as hex string e.g. "#00FFFF" (default: cyan) */
  meshColor?: string;
  /** Enable wireframe mode (default: false) */
  wireframe?: boolean;
  /** Enable occlusion so mesh behind walls is hidden (default: true) */
  enableOcclusion?: boolean;
  /** Maximum distance in meters to render mesh (default: 5.0) */
  maxRenderDistance?: number;
  /** Callback on mesh updates */
  onMeshUpdate?: (stats: MeshStats) => void;
  /** Callback when scan completes */
  onScanComplete?: (result: ExportResult) => void;
  /** Callback on errors */
  onError?: (error: string) => void;
}

export interface ARKitMeshScannerRef {
  startScanning: () => void;
  stopScanning: () => void;
  exportMesh: (filename: string) => Promise<ExportResult>;
  getMeshStats: () => Promise<MeshStats>;
  clearMesh: () => void;
  enterPreviewMode: () => void;
  exitPreviewMode: () => void;
}

// Native Components
const NativeARKitMeshScanner =
  Platform.OS === 'ios'
    ? requireNativeComponent<any>('ARKitMeshScannerView')
    : null;

const ARKitMeshScannerModule = NativeModules.ARKitMeshScannerModule;

// Check LiDAR Support
export const isLiDARSupported = async (): Promise<boolean> => {
  if (Platform.OS !== 'ios') {
    return false;
  }
  try {
    return await ARKitMeshScannerModule.isLiDARSupported();
  } catch {
    return false;
  }
};

// Get Memory Usage
export const getMemoryUsage = async (): Promise<MemoryUsage> => {
  if (Platform.OS !== 'ios') {
    return { usedMB: 0, usedBytes: 0 };
  }
  try {
    return await ARKitMeshScannerModule.getMemoryUsage();
  } catch {
    return { usedMB: 0, usedBytes: 0 };
  }
};

// Main Component
export const ARKitMeshScanner = forwardRef<
  ARKitMeshScannerRef,
  ARKitMeshScannerProps
>(
  (
    {
      style,
      showMesh = true,
      meshColor = '#00FFFF',
      wireframe = false,
      enableOcclusion = true,
      maxRenderDistance = 5.0,
      onMeshUpdate,
      onScanComplete,
      onError,
    },
    ref
  ) => {
    const nativeRef = useRef<any>(null);

    const getViewTag = useCallback(() => {
      return findNodeHandle(nativeRef.current);
    }, []);

    useImperativeHandle(
      ref,
      () => ({
        startScanning: () => {
          const viewTag = getViewTag();
          if (viewTag) {
            ARKitMeshScannerModule.startScanning(viewTag);
          }
        },

        stopScanning: () => {
          const viewTag = getViewTag();
          if (viewTag) {
            ARKitMeshScannerModule.stopScanning(viewTag);
          }
        },

        exportMesh: async (filename: string): Promise<ExportResult> => {
          const viewTag = getViewTag();
          if (!viewTag) {
            throw new Error('View not found');
          }
          return ARKitMeshScannerModule.exportMesh(viewTag, filename);
        },

        getMeshStats: async (): Promise<MeshStats> => {
          const viewTag = getViewTag();
          if (!viewTag) {
            throw new Error('View not found');
          }
          return ARKitMeshScannerModule.getMeshStats(viewTag);
        },

        clearMesh: () => {
          const viewTag = getViewTag();
          if (viewTag) {
            ARKitMeshScannerModule.clearMesh(viewTag);
          }
        },

        enterPreviewMode: () => {
          const viewTag = getViewTag();
          if (viewTag) {
            ARKitMeshScannerModule.enterPreviewMode(viewTag);
          }
        },

        exitPreviewMode: () => {
          const viewTag = getViewTag();
          if (viewTag) {
            ARKitMeshScannerModule.exitPreviewMode(viewTag);
          }
        },
      }),
      [getViewTag]
    );

    const handleMeshUpdate = useCallback(
      (event: MeshUpdateEvent) => {
        onMeshUpdate?.(event.nativeEvent);
      },
      [onMeshUpdate]
    );

    const handleScanComplete = useCallback(
      (event: { nativeEvent: ExportResult }) => {
        onScanComplete?.(event.nativeEvent);
      },
      [onScanComplete]
    );

    const handleError = useCallback(
      (event: ErrorEvent) => {
        onError?.(event.nativeEvent.message);
      },
      [onError]
    );

    if (Platform.OS !== 'ios' || !NativeARKitMeshScanner) {
      console.warn('ARKitMeshScanner is only available on iOS with LiDAR');
      return null;
    }

    return (
      <NativeARKitMeshScanner
        ref={nativeRef}
        style={[styles.container, style]}
        showMesh={showMesh}
        meshColorHex={meshColor}
        wireframe={wireframe}
        enableOcclusion={enableOcclusion}
        maxRenderDistance={maxRenderDistance}
        onMeshUpdate={handleMeshUpdate}
        onScanComplete={handleScanComplete}
        onError={handleError}
      />
    );
  }
);

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
});

// Hook for easier usage
export const useARKitMeshScanner = () => {
  const scannerRef = useRef<ARKitMeshScannerRef>(null);

  const startScanning = useCallback(() => {
    scannerRef.current?.startScanning();
  }, []);

  const stopScanning = useCallback(() => {
    scannerRef.current?.stopScanning();
  }, []);

  const exportMesh = useCallback(async (filename: string) => {
    if (!scannerRef.current) {
      throw new Error('Scanner not initialized');
    }
    return scannerRef.current.exportMesh(filename);
  }, []);

  const getMeshStats = useCallback(async () => {
    if (!scannerRef.current) {
      throw new Error('Scanner not initialized');
    }
    return scannerRef.current.getMeshStats();
  }, []);

  const clearMesh = useCallback(() => {
    scannerRef.current?.clearMesh();
  }, []);

  const enterPreviewMode = useCallback(() => {
    scannerRef.current?.enterPreviewMode();
  }, []);

  const exitPreviewMode = useCallback(() => {
    scannerRef.current?.exitPreviewMode();
  }, []);

  return {
    scannerRef,
    startScanning,
    stopScanning,
    exportMesh,
    getMeshStats,
    clearMesh,
    enterPreviewMode,
    exitPreviewMode,
  };
};

export default ARKitMeshScanner;
