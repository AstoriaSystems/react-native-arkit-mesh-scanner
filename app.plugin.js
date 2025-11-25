/**
 * Expo Config Plugin for react-native-arkit-mesh-scanner
 *
 * Created by Mergim Mavraj on 25.11.2025.
 * Copyright (c) 2025 Astoria Systems GmbH
 * Author: Mergim Mavraj
 *
 * MIT License
 */

const { withInfoPlist, withPlugins } = require('@expo/config-plugins');

/**
 * Adds required Info.plist entries for ARKit and Camera access
 */
const withARKitInfoPlist = (config) => {
  return withInfoPlist(config, (config) => {
    // Camera permission description
    config.modResults.NSCameraUsageDescription =
      config.modResults.NSCameraUsageDescription ||
      'This app requires camera access for AR mesh scanning with LiDAR';

    // Required device capabilities for LiDAR
    if (!config.modResults.UIRequiredDeviceCapabilities) {
      config.modResults.UIRequiredDeviceCapabilities = [];
    }

    const capabilities = config.modResults.UIRequiredDeviceCapabilities;

    // ARKit capability
    if (!capabilities.includes('arkit')) {
      capabilities.push('arkit');
    }

    // Ensure arm64 architecture (required for LiDAR devices)
    if (!capabilities.includes('arm64')) {
      capabilities.push('arm64');
    }

    return config;
  });
};

/**
 * Main plugin function
 */
const withARKitMeshScanner = (config) => {
  return withPlugins(config, [
    withARKitInfoPlist,
  ]);
};

module.exports = withARKitMeshScanner;
