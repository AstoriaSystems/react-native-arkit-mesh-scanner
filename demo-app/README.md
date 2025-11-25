# Mesh Scanner Demo

Demo app for testing the ARKit LiDAR Mesh Scanner on a real iOS device.

## Requirements

- Node.js >= 18
- Xcode >= 15
- iPhone 12 Pro or newer (or iPad Pro with LiDAR)
- macOS

## Installation & Running

```bash
# Navigate to the demo-app directory
cd demo-app

# Install dependencies
npm install

# Generate iOS project (prebuild)
npx expo prebuild --platform ios

# Install CocoaPods
cd ios && pod install && cd ..

# Run app on device
npx expo run:ios --device
```

## Important Notes

1. **Real Device Required**: ARKit with LiDAR only works on real devices, not in the simulator.

2. **LiDAR Sensor Required**: Only iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, 16 Pro, 17 Pro (and Max variants) as well as iPad Pro (2020+) have LiDAR.

3. **Developer Certificate**: You need an Apple Developer Account to install the app on your device.

## Troubleshooting

### "Device not found"
- Make sure your iPhone is connected via USB
- Trust your Mac on your iPhone
- Open Xcode and accept any licenses if needed

### Build Errors
```bash
# Clear cache and rebuild
npx expo prebuild --clean --platform ios
cd ios && pod install && cd ..
```

### Signing Errors
- Open `ios/MeshScannerDemo.xcworkspace` in Xcode
- Select your Development Team under Signing & Capabilities
- Build and Run directly from Xcode

## Demo App Features

- Live mesh visualization during scanning
- Mesh statistics (vertices, faces, anchors)
- 3D preview mode with gesture controls
- OBJ export with share dialog
- Customizable mesh color

## License

MIT License - Copyright (c) 2025 Astoria Systems GmbH
