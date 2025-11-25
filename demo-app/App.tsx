/**
 * Mesh Scanner Demo App
 *
 * Copyright (c) 2025 Astoria Systems GmbH
 * Author: Mergim Mavraj
 *
 * MIT License
 */

import React, { useState, useRef, useEffect } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Animated,
  Easing,
  Share,
  Alert,
} from 'react-native';
import {
  ARKitMeshScanner,
  MeshStats,
  ARKitMeshScannerRef,
} from 'react-native-arkit-mesh-scanner';

type ViewMode = 'ar' | 'preview';

export default function App() {
  const [isScanning, setIsScanning] = useState(false);
  const [meshStats, setMeshStats] = useState<MeshStats | null>(null);
  const [waitingForMesh, setWaitingForMesh] = useState(false);
  const [viewMode, setViewMode] = useState<ViewMode>('ar');
  const [isExporting, setIsExporting] = useState(false);
  const scannerRef = useRef<ARKitMeshScannerRef>(null);

  const pulseAnim = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    if (waitingForMesh) {
      const pulse = Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, {
            toValue: 1.2,
            duration: 800,
            easing: Easing.inOut(Easing.ease),
            useNativeDriver: true,
          }),
          Animated.timing(pulseAnim, {
            toValue: 1,
            duration: 800,
            easing: Easing.inOut(Easing.ease),
            useNativeDriver: true,
          }),
        ])
      );
      pulse.start();
      return () => pulse.stop();
    }
  }, [waitingForMesh, pulseAnim]);

  const handleStartScanning = () => {
    if (viewMode === 'preview') {
      scannerRef.current?.exitPreviewMode();
      setViewMode('ar');
    }
    scannerRef.current?.startScanning();
    setIsScanning(true);
    setWaitingForMesh(true);
    setMeshStats(null);
  };

  const handleStopScanning = () => {
    scannerRef.current?.stopScanning();
    setIsScanning(false);
    setWaitingForMesh(false);
  };

  const handleMeshUpdate = (stats: MeshStats) => {
    setMeshStats(stats);
    if (stats.vertexCount > 0) {
      setWaitingForMesh(false);
    }
  };

  const handleEnterPreview = () => {
    scannerRef.current?.enterPreviewMode();
    setViewMode('preview');
  };

  const handleExitPreview = () => {
    scannerRef.current?.exitPreviewMode();
    setViewMode('ar');
  };

  const handleNewScan = () => {
    if (viewMode === 'preview') {
      scannerRef.current?.exitPreviewMode();
    }
    scannerRef.current?.clearMesh();
    setMeshStats(null);
    setViewMode('ar');
  };

  const handleExport = async () => {
    if (!scannerRef.current) return;

    setIsExporting(true);
    try {
      const filename = `mesh_${Date.now()}`;
      const result = await scannerRef.current.exportMesh(filename);

      await Share.share({
        url: `file://${result.path}`,
        title: 'Mesh Export',
      });
    } catch (error) {
      Alert.alert('Export failed', String(error));
    } finally {
      setIsExporting(false);
    }
  };

  const hasMesh = meshStats && meshStats.vertexCount > 0;

  return (
    <View style={styles.container}>
      <ARKitMeshScanner
        ref={scannerRef}
        style={StyleSheet.absoluteFill}
        showMesh={true}
        meshColor="#2D2B83"
        wireframe={false}
        onMeshUpdate={handleMeshUpdate}
      />

      {/* AR Mode UI */}
      {viewMode === 'ar' && (
        <>
          {waitingForMesh && (
            <View style={styles.loadingOverlay}>
              <Animated.View style={[styles.loadingCircle, { transform: [{ scale: pulseAnim }] }]}>
                <ActivityIndicator size="large" color="#2D2B83" />
              </Animated.View>
              <Text style={styles.loadingText}>Searching for surfaces...</Text>
              <Text style={styles.loadingHint}>Move the device slowly</Text>
            </View>
          )}

          <View style={styles.statsContainer}>
            <Text style={styles.statsTitle}>
              {isScanning ? 'SCANNING' : hasMesh ? 'DONE' : 'READY'}
            </Text>
            <Text style={styles.statsText}>
              Vertices: {meshStats?.vertexCount?.toLocaleString() ?? 0}
            </Text>
            <Text style={styles.statsText}>
              Faces: {meshStats?.faceCount?.toLocaleString() ?? 0}
            </Text>
          </View>

          <View style={styles.controls}>
            {!isScanning ? (
              <TouchableOpacity
                style={[styles.button, styles.startButton]}
                onPress={handleStartScanning}
              >
                <Text style={styles.buttonText}>Start</Text>
              </TouchableOpacity>
            ) : (
              <TouchableOpacity
                style={[styles.button, styles.stopButton]}
                onPress={handleStopScanning}
              >
                <Text style={styles.buttonText}>Stop</Text>
              </TouchableOpacity>
            )}

            {!isScanning && hasMesh && (
              <TouchableOpacity
                style={[styles.button, styles.previewButton]}
                onPress={handleEnterPreview}
              >
                <Text style={styles.buttonText}>3D View</Text>
              </TouchableOpacity>
            )}
          </View>
        </>
      )}

      {/* Preview Mode UI */}
      {viewMode === 'preview' && (
        <>
          <View style={styles.previewHeader}>
            <Text style={styles.previewTitle}>3D Preview</Text>
            <Text style={styles.previewSubtitle}>Rotate and zoom with gestures</Text>
          </View>

          <View style={styles.previewStats}>
            <Text style={styles.previewStatsText}>
              {meshStats?.vertexCount?.toLocaleString()} Vertices
            </Text>
            <Text style={styles.previewStatsText}>
              {meshStats?.faceCount?.toLocaleString()} Faces
            </Text>
          </View>

          <View style={styles.previewControls}>
            <TouchableOpacity
              style={[styles.previewControlButton, styles.backButton]}
              onPress={handleExitPreview}
            >
              <Text style={styles.buttonText}>Back</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.previewControlButton, styles.exportButton]}
              onPress={handleExport}
              disabled={isExporting}
            >
              <Text style={styles.buttonText}>
                {isExporting ? 'Exporting...' : 'Export'}
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.previewControlButton, styles.newScanButton]}
              onPress={handleNewScan}
            >
              <Text style={styles.buttonText}>New</Text>
            </TouchableOpacity>
          </View>
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  loadingOverlay: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  loadingCircle: {
    width: 100,
    height: 100,
    borderRadius: 50,
    backgroundColor: 'rgba(255,255,255,0.95)',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 24,
  },
  loadingText: {
    color: '#FFF',
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 8,
  },
  loadingHint: {
    color: 'rgba(255,255,255,0.7)',
    fontSize: 14,
  },
  statsContainer: {
    position: 'absolute',
    top: 70,
    left: 16,
    backgroundColor: 'rgba(0,0,0,0.75)',
    padding: 14,
    borderRadius: 12,
  },
  statsTitle: {
    color: '#00AAFF',
    fontSize: 12,
    fontWeight: '700',
    marginBottom: 8,
    letterSpacing: 1,
  },
  statsText: {
    color: '#FFF',
    fontSize: 14,
    marginBottom: 4,
  },
  controls: {
    position: 'absolute',
    bottom: 60,
    left: 0,
    right: 0,
    alignItems: 'center',
    gap: 12,
  },
  button: {
    paddingHorizontal: 50,
    paddingVertical: 16,
    borderRadius: 28,
    minWidth: 160,
    alignItems: 'center',
  },
  startButton: {
    backgroundColor: '#34C759',
  },
  stopButton: {
    backgroundColor: '#FF3B30',
  },
  previewButton: {
    backgroundColor: '#5856D6',
  },
  buttonText: {
    color: '#FFF',
    fontSize: 18,
    fontWeight: 'bold',
  },
  // Preview Mode
  previewHeader: {
    position: 'absolute',
    top: 70,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  previewTitle: {
    color: '#FFF',
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 4,
  },
  previewSubtitle: {
    color: 'rgba(255,255,255,0.6)',
    fontSize: 14,
  },
  previewStats: {
    position: 'absolute',
    top: 140,
    left: 16,
    backgroundColor: 'rgba(0,0,0,0.6)',
    padding: 12,
    borderRadius: 10,
  },
  previewStatsText: {
    color: '#00AAFF',
    fontSize: 14,
    marginBottom: 4,
  },
  previewControls: {
    position: 'absolute',
    bottom: 60,
    left: 16,
    right: 16,
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 8,
  },
  previewControlButton: {
    flex: 1,
    paddingVertical: 16,
    borderRadius: 28,
    alignItems: 'center',
  },
  backButton: {
    backgroundColor: '#5856D6',
  },
  exportButton: {
    backgroundColor: '#34C759',
  },
  newScanButton: {
    backgroundColor: '#FF9500',
  },
});
