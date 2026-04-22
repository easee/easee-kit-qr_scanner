# CocoaPods → SPM Migration Design

**Date:** 2026-04-22  
**Scope:** iOS plugin only — Android, Dart API, and Flutter method channel contract are untouched.

---

## Goal

Remove the `MTBBarcodeScanner` CocoaPods dependency from the iOS plugin and add Swift Package Manager support, without changing any consumer-facing behaviour.

---

## Files Changed

| File | Change |
|---|---|
| `ios/Classes/QRView.swift` | Full rewrite: replace MTBBarcodeScanner with AVFoundation |
| `ios/Package.swift` | New: SPM package declaration |
| `ios/qr_code_scanner.podspec` | Remove `MTBBarcodeScanner` dependency, raise deployment target to 16.1 |

**Unchanged:** `FlutterQrPlugin.h`, `FlutterQrPlugin.m`, `QRViewFactory.swift`, `SwiftFlutterQrPlugin.swift`, all Dart code, Android code.

---

## Architecture

The Flutter↔native boundary (method channel, platform view registration) is untouched. `QRView.swift` is the only implementation file that changes. Everything above it — Dart API, channel method names, argument shapes, return values — stays identical.

`QRView` owns an `AVCaptureSession` stack directly:
- `AVCaptureDeviceInput` — active camera input (swapped on flip)
- `AVCaptureMetadataOutput` — barcode detection; `QRView` is the delegate
- `AVCaptureVideoPreviewLayer` — added as sublayer of `previewView`
- A private `sessionQueue: DispatchQueue` — all session mutations run here

---

## Behaviour Mapping

| MTBBarcodeScanner | AVFoundation equivalent |
|---|---|
| `MTBBarcodeScanner(previewView:)` | Create `AVCaptureSession`, add `AVCaptureVideoPreviewLayer` as sublayer |
| `requestCameraPermission(success:)` | `AVCaptureDevice.requestAccess(for: .video, completionHandler:)` |
| `startScanning(with:resultBlock:)` | `session.startRunning()` on `sessionQueue` + `AVCaptureMetadataOutputObjectsDelegate` |
| `stopScanning()` | `session.stopRunning()` on `sessionQueue` |
| `isScanning()` | `session.isRunning` |
| `freezeCapture()` | `session.stopRunning()` on `sessionQueue` |
| `unfreezeCapture()` | `session.startRunning()` on `sessionQueue` |
| `flipCamera()` | Swap `AVCaptureDeviceInput` for the opposite `AVCaptureDevice.Position` |
| `hasOppositeCamera()` | `AVCaptureDevice.DiscoverySession` queried for the opposite position |
| `sc.camera` (rawValue) | See Camera Facing section below |
| `hasTorch()` | `device.hasTorch && device.isTorchAvailable` |
| `toggleTorch()` | Toggle `device.torchMode` between `.on` and `.off` |
| `sc.torchMode.rawValue != 0` | `device.torchMode == .on` |
| `scanner?.scanRect` | `metadataOutput.rectOfInterest` (see Scan Rect section below) |
| `sc.previewLayer` | `previewLayer: AVCaptureVideoPreviewLayer` property on `QRView` |

---

## Camera Facing

The Flutter method channel uses `0 = back, 1 = front`. `AVCaptureDevice.Position` uses `.back = 1, .front = 2`. These must never be conflated.

A private mapping is introduced:

```swift
// Channel integer → AVFoundation position
func avPosition(from channelValue: Int) -> AVCaptureDevice.Position {
    channelValue == 1 ? .front : .back
}

// AVFoundation position → channel integer
func channelValue(from position: AVCaptureDevice.Position) -> Int {
    position == .front ? 1 : 0
}
```

`getCameraInfo` and `getSystemFeatures` both return `channelValue(from:)` — never the AVFoundation rawValue.

`cameraFacing` is stored as `AVCaptureDevice.Position` internally; the init converts the incoming `params["cameraFacing"]` Double via `avPosition(from:)`.

---

## Threading

AVFoundation requires that `startRunning()` and `stopRunning()` are not called on the main thread.

- A `sessionQueue = DispatchQueue(label: "qr_scanner.session")` is created on init.
- All `session.startRunning()`, `session.stopRunning()`, and input/output reconfigurations (`session.beginConfiguration` / `session.commitConfiguration`) run on `sessionQueue`.
- `AVCaptureMetadataOutputObjectsDelegate` callbacks (`metadataOutput(_:didOutput:from:)`) arrive on the main queue (output's `setMetadataObjectsDelegate(_:queue: .main)`).
- All `channel.invokeMethod(...)` calls are already on the main queue via this delegate dispatch.
- Flutter `result(...)` callbacks from methods like `startScan` are called on the main queue via `DispatchQueue.main.async` where needed.

---

## Scan Rect (rectOfInterest)

`setDimensions` may be called before `startScan`. `metadataOutput.rectOfInterest` requires the preview layer to have an established layout to correctly convert coordinates.

Approach:
- `setDimensions` stores a `pendingScanRect: CGRect?` (in `previewView` coordinate space).
- After `session.startRunning()` completes, apply `pendingScanRect` if set:  
  `metadataOutput.rectOfInterest = previewLayer.metadataOutputRectConverted(fromLayerRect: pendingScanRect)`
- If `setDimensions` is called after scanning has started, apply immediately.

---

## Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "qr_code_scanner",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "qr-code-scanner", targets: ["qr_code_scanner"])
    ],
    targets: [
        .target(
            name: "qr_code_scanner",
            path: "Classes"
        )
    ]
)
```

No external dependencies.

---

## Podspec Changes

- Remove: `s.dependency 'MTBBarcodeScanner'`
- Change: `s.ios.deployment_target = '16.1'`
- Change: `s.swift_version = '5.9'`

---

## What Does Not Change

- All method channel method names and argument shapes
- All `FlutterError` codes and messages
- `QRCodeTypes` barcode type integer → `AVMetadataObject.ObjectType` mapping
- Barcode result dictionary keys (`code`, `type`, `rawBytes`)
- `onPermissionSet` and `onRecognizeQR` invoke method names
- Android, Dart, and web platform code
