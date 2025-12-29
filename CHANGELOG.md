# Changelog

All notable changes to this project will be documented in this file.

## [1.3.1] - 2025-12-29

### Fixed
- **Memory optimization**: Removed `receivesLighting` which caused RAM accumulation during scanning
- **Per-anchor throttling**: Added 1-second throttle per anchor to drastically reduce buffer allocations
- **3D Preview coverage**: Fixed missing mesh parts by sorting anchors smallest-first for better spatial coverage
- **Preview vertex limit**: Increased from 200K to 500K vertices, uses all anchors when under limit

### Removed
- Removed unused files: `CapturedFrame.swift`, `MeshDecimator.swift`, `MeshExporter.swift`, `MeshStreamWriter.swift`
- Removed `cameraDimming` feature (incompatible with ARKit debug visualization)

### Changed
- Mesh visualization now uses only `showSceneUnderstanding` debug option (memory-safe)
- Preview loading prioritizes smaller anchors for better spatial coverage

## [1.3.0] - 2025-12-28

### Added
- Complete visualization using ARKit's built-in debug wireframe
- Disk-based storage for unlimited scan duration
- Thread-safe architecture with NSLock protection
- Memory pressure monitoring

### Fixed
- Thread-safety crash in mesh buffer access

## [1.2.0] - 2025-12-27

### Added
- Fast mesh display with adaptive throttling
- Performance optimizations for huge scans

## [1.1.0] - 2025-12-26

### Fixed
- 100% thread-safe mesh handling
- Crash prevention for ARKit buffer access

## [1.0.0] - 2025-12-25

### Added
- Initial release
- Real-time 3D mesh scanning using LiDAR sensor
- Live mesh visualization
- 3D preview mode with gesture controls
- Export scanned meshes as OBJ files
- Expo and EAS Build support via config plugin
