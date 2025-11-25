import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  Share,
  ActivityIndicator,
} from 'react-native';
import {
  ARKitMeshScanner,
  useARKitMeshScanner,
  isLiDARSupported,
  MeshStats,
  ExportResult,
} from 'react-native-arkit-mesh-scanner';

const MeshScannerExample: React.FC = () => {
  const [isSupported, setIsSupported] = useState<boolean | null>(null);
  const [isScanning, setIsScanning] = useState(false);
  const [meshStats, setMeshStats] = useState<MeshStats | null>(null);
  const [isExporting, setIsExporting] = useState(false);

  const {
    scannerRef,
    startScanning,
    stopScanning,
    exportMesh,
    clearMesh,
  } = useARKitMeshScanner();

  useEffect(() => {
    checkLiDARSupport();
  }, []);

  const checkLiDARSupport = async () => {
    const supported = await isLiDARSupported();
    setIsSupported(supported);
  };

  const handleStartScanning = () => {
    startScanning();
    setIsScanning(true);
  };

  const handleStopScanning = () => {
    stopScanning();
    setIsScanning(false);
  };

  const handleExportMesh = async () => {
    if (!meshStats || meshStats.vertexCount === 0) {
      Alert.alert('Fehler', 'Kein Mesh zum Exportieren vorhanden');
      return;
    }

    setIsExporting(true);

    try {
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const filename = `room_scan_${timestamp}`;
      const result: ExportResult = await exportMesh(filename);

      Alert.alert(
        'Export erfolgreich',
        `Mesh gespeichert:\n\nPfad: ${result.path}\nVertices: ${result.vertexCount}\nFaces: ${result.faceCount}`,
        [
          { text: 'OK' },
          {
            text: 'Teilen',
            onPress: () => shareFile(result.path),
          },
        ]
      );
    } catch (error: any) {
      Alert.alert('Export fehlgeschlagen', error.message);
    } finally {
      setIsExporting(false);
    }
  };

  const shareFile = async (path: string) => {
    try {
      await Share.share({
        url: `file://${path}`,
        title: 'Room Mesh Export',
      });
    } catch (error) {
      console.error('Share error:', error);
    }
  };

  const handleClearMesh = () => {
    Alert.alert(
      'Mesh löschen',
      'Möchtest du das aktuelle Mesh wirklich löschen?',
      [
        { text: 'Abbrechen', style: 'cancel' },
        {
          text: 'Löschen',
          style: 'destructive',
          onPress: () => {
            clearMesh();
            setMeshStats(null);
          },
        },
      ]
    );
  };

  const handleMeshUpdate = (stats: MeshStats) => {
    setMeshStats(stats);
  };

  const handleError = (error: string) => {
    Alert.alert('Fehler', error);
    setIsScanning(false);
  };

  // Loading state
  if (isSupported === null) {
    return (
      <View style={styles.centerContainer}>
        <ActivityIndicator size="large" color="#007AFF" />
        <Text style={styles.loadingText}>Prüfe LiDAR Unterstützung...</Text>
      </View>
    );
  }

  // Not supported
  if (!isSupported) {
    return (
      <View style={styles.centerContainer}>
        <Text style={styles.errorIcon}>⚠️</Text>
        <Text style={styles.errorTitle}>LiDAR nicht verfügbar</Text>
        <Text style={styles.errorText}>
          Dieses Gerät unterstützt kein LiDAR Mesh Scanning.
          {'\n\n'}
          Benötigt: iPhone 12 Pro oder neuer, iPad Pro mit LiDAR
        </Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      {/* AR View */}
      <ARKitMeshScanner
        ref={scannerRef}
        style={styles.arView}
        onMeshUpdate={handleMeshUpdate}
        onError={handleError}
      />

      {/* Stats Overlay */}
      <View style={styles.statsContainer}>
        <Text style={styles.statsTitle}>Mesh Statistiken</Text>
        <View style={styles.statsRow}>
          <Text style={styles.statsLabel}>Anchors:</Text>
          <Text style={styles.statsValue}>{meshStats?.anchorCount ?? 0}</Text>
        </View>
        <View style={styles.statsRow}>
          <Text style={styles.statsLabel}>Vertices:</Text>
          <Text style={styles.statsValue}>
            {meshStats?.vertexCount?.toLocaleString() ?? 0}
          </Text>
        </View>
        <View style={styles.statsRow}>
          <Text style={styles.statsLabel}>Faces:</Text>
          <Text style={styles.statsValue}>
            {meshStats?.faceCount?.toLocaleString() ?? 0}
          </Text>
        </View>
      </View>

      {/* Scanning Indicator */}
      {isScanning && (
        <View style={styles.scanningIndicator}>
          <View style={styles.scanningDot} />
          <Text style={styles.scanningText}>Scanning...</Text>
        </View>
      )}

      {/* Controls */}
      <View style={styles.controlsContainer}>
        {!isScanning ? (
          <TouchableOpacity
            style={[styles.button, styles.startButton]}
            onPress={handleStartScanning}
          >
            <Text style={styles.buttonText}>Scan starten</Text>
          </TouchableOpacity>
        ) : (
          <TouchableOpacity
            style={[styles.button, styles.stopButton]}
            onPress={handleStopScanning}
          >
            <Text style={styles.buttonText}>Scan stoppen</Text>
          </TouchableOpacity>
        )}

        <View style={styles.buttonRow}>
          <TouchableOpacity
            style={[
              styles.button,
              styles.secondaryButton,
              (!meshStats || meshStats.vertexCount === 0) && styles.disabledButton,
            ]}
            onPress={handleExportMesh}
            disabled={!meshStats || meshStats.vertexCount === 0 || isExporting}
          >
            {isExporting ? (
              <ActivityIndicator color="#FFF" />
            ) : (
              <Text style={styles.buttonText}>Als OBJ exportieren</Text>
            )}
          </TouchableOpacity>

          <TouchableOpacity
            style={[
              styles.button,
              styles.clearButton,
              (!meshStats || meshStats.vertexCount === 0) && styles.disabledButton,
            ]}
            onPress={handleClearMesh}
            disabled={!meshStats || meshStats.vertexCount === 0}
          >
            <Text style={styles.buttonText}>Löschen</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  centerContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#1C1C1E',
    padding: 20,
  },
  arView: {
    flex: 1,
  },
  loadingText: {
    color: '#FFF',
    marginTop: 16,
    fontSize: 16,
  },
  errorIcon: {
    fontSize: 64,
    marginBottom: 16,
  },
  errorTitle: {
    color: '#FFF',
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 12,
  },
  errorText: {
    color: '#8E8E93',
    fontSize: 16,
    textAlign: 'center',
    lineHeight: 24,
  },
  statsContainer: {
    position: 'absolute',
    top: 60,
    left: 16,
    backgroundColor: 'rgba(0, 0, 0, 0.7)',
    borderRadius: 12,
    padding: 16,
    minWidth: 160,
  },
  statsTitle: {
    color: '#FFF',
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 12,
  },
  statsRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  statsLabel: {
    color: '#8E8E93',
    fontSize: 14,
  },
  statsValue: {
    color: '#FFF',
    fontSize: 14,
    fontWeight: '500',
  },
  scanningIndicator: {
    position: 'absolute',
    top: 60,
    right: 16,
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(255, 59, 48, 0.9)',
    borderRadius: 20,
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  scanningDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: '#FFF',
    marginRight: 8,
  },
  scanningText: {
    color: '#FFF',
    fontSize: 14,
    fontWeight: '600',
  },
  controlsContainer: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    padding: 16,
    paddingBottom: 40,
    backgroundColor: 'rgba(0, 0, 0, 0.8)',
  },
  button: {
    borderRadius: 12,
    paddingVertical: 16,
    alignItems: 'center',
    justifyContent: 'center',
  },
  startButton: {
    backgroundColor: '#34C759',
    marginBottom: 12,
  },
  stopButton: {
    backgroundColor: '#FF3B30',
    marginBottom: 12,
  },
  secondaryButton: {
    backgroundColor: '#007AFF',
    flex: 1,
    marginRight: 8,
  },
  clearButton: {
    backgroundColor: '#FF9500',
    width: 100,
  },
  disabledButton: {
    opacity: 0.5,
  },
  buttonText: {
    color: '#FFF',
    fontSize: 16,
    fontWeight: '600',
  },
  buttonRow: {
    flexDirection: 'row',
  },
});

export default MeshScannerExample;
