# react-native-arkit-mesh-scanner

A React Native library for 3D mesh scanning using ARKit and LiDAR on iOS devices.

## Features

- Real-time 3D mesh scanning using LiDAR sensor
- Live mesh visualization with customizable colors
- 3D preview mode with gesture controls (rotate, zoom)
- Export scanned meshes as OBJ files
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

### Real-time Rendering

Real-time mesh rendering uses ARKit's native mesh data directly for maximum performance. No decimation is applied during scanning to ensure smooth frame rates.

### Mesh Decimation (Export Only)

When exporting meshes, automatic decimation reduces file size through grid-based vertex clustering:

| Quality | Grid Size | Typical Reduction |
|---------|-----------|-------------------|
| `low` | 5cm | ~90% fewer vertices |
| `medium` | 2.5cm | ~75% fewer vertices |
| `high` | 1.5cm | ~50% fewer vertices |
| `full` | None | Original mesh |

Decimation is applied automatically during export to produce smaller OBJ files while preserving mesh quality.

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
  maxRenderDistance={4.0}
/>
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

Copyright (c) 2025 Astoria Systems GmbH
Author: Mergim Mavraj
This file is part of the React Native ARKit Mesh Scanner.
Dual License:
---------------------------------------------------------------------------
Commercial License
---------------------------------------------------------------------------
If you purchased a commercial license from Astoria Systems GmbH, you are
granted the rights defined in the commercial license agreement. This license
permits the use of this software in closed-source, proprietary, or
competitive commercial products.
To obtain a commercial license, please contact:
licensing@astoria.systems
---------------------------------------------------------------------------
Open Source License (AGPL-3.0)
---------------------------------------------------------------------------
If you have not purchased a commercial license, this software is offered
under the terms of the GNU Affero General Public License v3.0 (AGPL-3.0).
You may use, modify, and redistribute this software under the conditions of
the AGPL-3.0. Any software that incorporates or interacts with this code
over a network must also be released under the AGPL-3.0.
A copy of the AGPL-3.0 license is provided in the repository's LICENSE file
or at: https://www.gnu.org/licenses/agpl-3.0.html
---------------------------------------------------------------------------
Disclaimer
---------------------------------------------------------------------------
This software is provided "AS IS", without warranty of any kind, express or
implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or copyright holders be liable for any claim, damages or other
liability, whether in an action of contract, tort or otherwise, arising from,
out of or in connection with the software or the use or other dealings in
the software.