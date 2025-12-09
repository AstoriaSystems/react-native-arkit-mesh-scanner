# react-native-arkit-mesh-scanner

A React Native library for 3D mesh scanning using ARKit and LiDAR on iOS devices.

## Features

- Real-time 3D mesh scanning using LiDAR sensor
- Live mesh visualization with customizable colors
- 3D preview mode with gesture controls (rotate, zoom)
- Export scanned meshes as OBJ files
- **Memory-safe disk-based storage** - Scan entire buildings without RAM issues
- **Thread-safe architecture** - No crashes during scan, visualization, or export
- Expo and EAS Build support via config plugin

## Requirements

- iOS 14.0+
- iPhone 12 Pro or newer (devices with LiDAR sensor)
- React Native 0.70+
- Xcode 14+

## Installation

### From GitHub

```bash
npm install github:AstoriaSystems/react-native-arkit-mesh-scanner
# or
yarn add github:AstoriaSystems/react-native-arkit-mesh-scanner
```

### iOS Setup

```bash
cd ios && pod install
```

### Expo / EAS Build

Add the dependency and plugin to your project:

```bash
npx expo install github:AstoriaSystems/react-native-arkit-mesh-scanner
```

Then add the plugin to your `app.json` or `app.config.js`:

```json
{
  "expo": {
    "plugins": ["react-native-arkit-mesh-scanner"]
  }
}
```

The plugin automatically adds:
- Camera usage permission (`NSCameraUsageDescription`)
- Required device capabilities (`arkit`, `arm64`)

## Usage

### Basic Example

```tsx
import React, { useRef, useState } from 'react';
import { View, Button, Text } from 'react-native';
import {
  ARKitMeshScanner,
  ARKitMeshScannerRef,
  isLiDARSupported,
  MeshStats,
} from 'react-native-arkit-mesh-scanner';

export default function ScannerScreen() {
  const scannerRef = useRef<ARKitMeshScannerRef>(null);
  const [isScanning, setIsScanning] = useState(false);
  const [stats, setStats] = useState<MeshStats | null>(null);

  const handleStartScan = () => {
    scannerRef.current?.startScanning();
    setIsScanning(true);
  };

  const handleStopScan = () => {
    scannerRef.current?.stopScanning();
    setIsScanning(false);
  };

  const handleExport = async () => {
    try {
      const result = await scannerRef.current?.exportMesh('my-scan');
      console.log('Exported to:', result?.path);
    } catch (error) {
      console.error('Export failed:', error);
    }
  };

  const handlePreview = () => {
    scannerRef.current?.enterPreviewMode();
  };

  return (
    <View style={{ flex: 1 }}>
      <ARKitMeshScanner
        ref={scannerRef}
        style={{ flex: 1 }}
        meshColor="#00FFFF"
        showMesh={true}
        wireframe={false}
        onMeshUpdate={setStats}
        onError={(error) => console.error(error)}
      />

      <View style={{ padding: 20 }}>
        {stats && (
          <Text>
            Vertices: {stats.vertexCount} | Faces: {stats.faceCount}
          </Text>
        )}

        <Button
          title={isScanning ? 'Stop Scanning' : 'Start Scanning'}
          onPress={isScanning ? handleStopScan : handleStartScan}
        />
        <Button title="Preview 3D" onPress={handlePreview} />
        <Button title="Export OBJ" onPress={handleExport} />
      </View>
    </View>
  );
}
```

### Using the Hook

```tsx
import { useARKitMeshScanner, ARKitMeshScanner } from 'react-native-arkit-mesh-scanner';

function MyScanner() {
  const {
    scannerRef,
    startScanning,
    stopScanning,
    exportMesh,
    getMeshStats,
    clearMesh,
    enterPreviewMode,
    exitPreviewMode,
  } = useARKitMeshScanner();

  return (
    <ARKitMeshScanner
      ref={scannerRef}
      style={{ flex: 1 }}
      meshColor="#FF6600"
    />
  );
}
```

## API Reference

### Components

#### `<ARKitMeshScanner />`

Main component for mesh scanning.

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `style` | `ViewStyle` | - | Container style |
| `showMesh` | `boolean` | `true` | Show mesh overlay during scanning |
| `meshColor` | `string` | `"#00FFFF"` | Mesh color as hex string |
| `wireframe` | `boolean` | `false` | Show mesh as wireframe |
| `enableOcclusion` | `boolean` | `true` | Hide mesh behind walls/objects |
| `maxRenderDistance` | `number` | `5.0` | Max distance in meters to render mesh |
| `onMeshUpdate` | `(stats: MeshStats) => void` | - | Called when mesh updates |
| `onScanComplete` | `(result: ExportResult) => void` | - | Called when scan completes |
| `onError` | `(error: string) => void` | - | Called on errors |

### Ref Methods

Access these methods via `ref`:

```tsx
const scannerRef = useRef<ARKitMeshScannerRef>(null);
```

| Method | Returns | Description |
|--------|---------|-------------|
| `startScanning()` | `void` | Start mesh scanning |
| `stopScanning()` | `void` | Stop mesh scanning |
| `exportMesh(filename)` | `Promise<ExportResult>` | Export mesh as OBJ file |
| `getMeshStats()` | `Promise<MeshStats>` | Get current mesh statistics |
| `clearMesh()` | `void` | Clear all scanned mesh data |
| `enterPreviewMode()` | `void` | Enter 3D preview mode |
| `exitPreviewMode()` | `void` | Exit 3D preview mode |

### Functions

#### `isLiDARSupported()`

Check if the device supports LiDAR scanning.

```tsx
import { isLiDARSupported } from 'react-native-arkit-mesh-scanner';

const supported = await isLiDARSupported();
if (!supported) {
  alert('This device does not have a LiDAR sensor');
}
```

#### `getMemoryUsage()`

Get current app memory usage. Useful for monitoring during long scans.

```tsx
import { getMemoryUsage } from 'react-native-arkit-mesh-scanner';

const memory = await getMemoryUsage();
console.log(`Memory: ${memory.usedMB} MB`);
```

Returns:
```typescript
interface MemoryUsage {
  usedMB: number;    // Memory usage in megabytes
  usedBytes: number; // Memory usage in bytes
}
```

### Types

```typescript
interface MeshStats {
  anchorCount: number;
  vertexCount: number;
  faceCount: number;
  isScanning?: boolean;
}

interface ExportResult {
  path: string;
  vertexCount: number;
  faceCount: number;
}

interface MemoryUsage {
  usedMB: number;
  usedBytes: number;
}

interface ARKitMeshScannerRef {
  startScanning: () => void;
  stopScanning: () => void;
  exportMesh: (filename: string) => Promise<ExportResult>;
  getMeshStats: () => Promise<MeshStats>;
  clearMesh: () => void;
  enterPreviewMode: () => void;
  exitPreviewMode: () => void;
}
```

## Performance Optimization

For large scans, the library includes several optimizations to maintain smooth performance:

### Memory-Safe Disk Storage

Starting with v1.2.0, mesh data is stored on disk instead of RAM, enabling unlimited scan sizes:

- **Per-anchor files**: Each mesh anchor gets its own file on disk
- **No duplicates**: Updates overwrite existing anchor files (not append)
- **Thread-safe**: All disk I/O happens on a background queue
- **Buffer safety**: ARKit buffers are copied via `memcpy` before background processing

This architecture allows scanning entire buildings (1+ hour scans) without memory issues or crashes.

### Visualization Limits

To maintain performance, visualization is limited to ~150 anchors in RAM. The library prioritizes larger anchors and automatically manages what's displayed. All mesh data is preserved on disk regardless of visualization limits.

### Real-time Rendering

Real-time mesh rendering uses ARKit's native mesh data directly for maximum performance. Mesh visualization happens BEFORE disk storage to ensure responsive display.

### Occlusion

When `enableOcclusion` is true (default), mesh behind walls and objects is automatically hidden, preventing visual confusion when moving between rooms.

### Distance Culling

The `maxRenderDistance` prop limits how far mesh is rendered. Mesh anchors beyond this distance are hidden, improving performance in large environments.

```tsx
<ARKitMeshScanner
  maxRenderDistance={3.0}  // Only show mesh within 3 meters
/>
```

### Recommended Settings for Large Scans

```tsx
<ARKitMeshScanner
  enableOcclusion={true}
  maxRenderDistance={10.0}  // Increased since v1.2.0 handles large scans well
/>
```

### Monitoring Memory During Long Scans

```tsx
import { getMemoryUsage } from 'react-native-arkit-mesh-scanner';

// Check periodically during scanning
const memory = await getMemoryUsage();
if (memory.usedMB > 800) {
  console.warn('Memory usage high:', memory.usedMB, 'MB');
}
```

## Preview Mode

The 3D preview mode allows you to inspect the scanned mesh:

- **Pan gesture**: Rotate the model
- **Pinch gesture**: Zoom in/out
- **Double tap**: Reset view

The preview uses the `meshColor` prop for the model color with proper lighting to show depth and surface details.

## Export Format

Meshes are exported as Wavefront OBJ files:

```
# Exported by react-native-arkit-mesh-scanner
# Vertices: 12345
# Faces: 23456

v 0.123 0.456 0.789
v ...
vn 0.0 1.0 0.0
vn ...
f 1//1 2//2 3//3
f ...
```

Files are saved to the app's Documents directory and can be shared or processed further.

## Troubleshooting

### "LiDAR not supported" error

This library requires a device with a LiDAR sensor:

**iPhone:**
- iPhone 12 Pro / Pro Max (2020)
- iPhone 13 Pro / Pro Max (2021)
- iPhone 14 Pro / Pro Max (2022)
- iPhone 15 Pro / Pro Max (2023)
- iPhone 16 Pro / Pro Max (2024)
- iPhone 17 Pro / Pro Max (2025)

**iPad:**
- iPad Pro 11" (2nd gen and later, 2020+)
- iPad Pro 12.9" (4th gen and later, 2020+)

### Camera permission denied

Ensure you have the camera permission in your `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app requires camera access for AR mesh scanning</string>
```

### Build errors with Expo

Make sure to rebuild with EAS after adding the plugin:

```bash
eas build --platform ios
```

## License

This software is dual-licensed:

- **AGPL-3.0** - Free for open source projects
- **Commercial License** - For closed-source/proprietary use

See [LICENSE](LICENSE) for details or contact licensing@astoria.systems for commercial licensing.

© 2025 Astoria Systems GmbH