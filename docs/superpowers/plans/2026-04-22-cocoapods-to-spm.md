# CocoaPods → SPM Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `MTBBarcodeScanner` CocoaPods dependency in the iOS plugin with native AVFoundation, and add a `Package.swift` for Swift Package Manager support, without changing any consumer-facing behaviour.

**Architecture:** `QRView.swift` is rewritten to own an `AVCaptureSession` stack (input, metadata output, preview layer) directly, replacing all `MTBBarcodeScanner` calls with their AVFoundation equivalents. A camera-facing mapping function bridges the channel's `0=back / 1=front` integer protocol to `AVCaptureDevice.Position`. The podspec is updated in place and a `Package.swift` is added alongside it.

**Tech Stack:** Swift 5.9, AVFoundation, Flutter plugin method channel, Swift Package Manager

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `ios/Classes/QRView.swift` | Rewrite | Owns AVCaptureSession, implements all method channel handlers |
| `ios/Package.swift` | Create | SPM package declaration, no external dependencies |
| `ios/qr_code_scanner.podspec` | Modify | Remove MTBBarcodeScanner dep, raise deployment target |

`FlutterQrPlugin.h`, `FlutterQrPlugin.m`, `QRViewFactory.swift`, `SwiftFlutterQrPlugin.swift` — **not touched**.

---

### Task 1: Rewrite QRView.swift with AVFoundation

**Files:**
- Modify: `ios/Classes/QRView.swift`

This task replaces the entire file. The public interface (init signature, `view()` return, all method channel handler signatures) is identical to the current implementation.

- [ ] **Step 1: Replace the entire contents of `ios/Classes/QRView.swift` with the following**

```swift
import Foundation
import AVFoundation
import Flutter

public class QRView: NSObject, FlutterPlatformView, AVCaptureMetadataOutputObjectsDelegate {

    private var previewView: UIView
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureSession: AVCaptureSession?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var currentDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "net.touchcapture.qr.sessionQueue")

    private var cameraPosition: AVCaptureDevice.Position
    private var pendingScanRect: CGRect?
    private var allowedBarcodeTypes: [AVMetadataObject.ObjectType] = []
    private var scanResultBlock: (([AVMetadataObject]) -> Void)?

    var registrar: FlutterPluginRegistrar
    var channel: FlutterMethodChannel

    // Channel integer (0=back, 1=front) → AVCaptureDevice.Position
    private func avPosition(from channelValue: Int) -> AVCaptureDevice.Position {
        channelValue == 1 ? .front : .back
    }

    // AVCaptureDevice.Position → channel integer (0=back, 1=front)
    private func channelValue(from position: AVCaptureDevice.Position) -> Int {
        position == .front ? 1 : 0
    }

    private let QRCodeTypes: [Int: AVMetadataObject.ObjectType] = [
        0: .aztec,
        1: .qr,
        2: .code39,
        3: .code93,
        4: .code128,
        5: .dataMatrix,
        6: .ean8,
        7: .ean13,
        8: .interleaved2of5,
        9: .qr,
        10: .pdf417,
        11: .qr,
        12: .qr,
        13: .qr,
        14: .ean13,
        15: .upce
    ]

    public init(withFrame frame: CGRect,
                withRegistrar registrar: FlutterPluginRegistrar,
                withId id: Int64,
                params: Dictionary<String, Any>) {
        self.registrar = registrar
        self.previewView = UIView(frame: frame)
        let facingRaw = Int(params["cameraFacing"] as! Double)
        self.cameraPosition = facingRaw == 1 ? .front : .back
        self.channel = FlutterMethodChannel(
            name: "net.touchcapture.qr.flutterqr/qrview_\(id)",
            binaryMessenger: registrar.messenger()
        )
    }

    deinit {
        sessionQueue.sync {
            captureSession?.stopRunning()
        }
    }

    public func view() -> UIView {
        channel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "setDimensions":
                let args = call.arguments as! Dictionary<String, Double>
                self?.setDimensions(result,
                                    width: args["width"] ?? 0,
                                    height: args["height"] ?? 0,
                                    scanAreaWidth: args["scanAreaWidth"] ?? 0,
                                    scanAreaHeight: args["scanAreaHeight"] ?? 0,
                                    scanAreaOffset: args["scanAreaOffset"] ?? 0)
            case "startScan":
                self?.startScan(call.arguments as! Array<Int>, result)
            case "flipCamera":
                self?.flipCamera(result)
            case "toggleFlash":
                self?.toggleFlash(result)
            case "pauseCamera":
                self?.pauseCamera(result)
            case "stopCamera":
                self?.stopCamera(result)
            case "resumeCamera":
                self?.resumeCamera(result)
            case "getCameraInfo":
                self?.getCameraInfo(result)
            case "getFlashInfo":
                self?.getFlashInfo(result)
            case "getSystemFeatures":
                self?.getSystemFeatures(result)
            default:
                result(FlutterMethodNotImplemented)
            }
        })
        return previewView
    }

    // MARK: - setDimensions

    func setDimensions(_ result: @escaping FlutterResult,
                       width: Double, height: Double,
                       scanAreaWidth: Double, scanAreaHeight: Double,
                       scanAreaOffset: Double) {
        previewView.frame = CGRect(x: 0, y: 0, width: width, height: height)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.previewLayer?.frame = self.previewView.bounds
        }

        if scanAreaWidth != 0 && scanAreaHeight != 0 {
            let midX = previewView.bounds.midX
            let midY = previewView.bounds.midY
            var rect = CGRect(
                x: Double(midX) - scanAreaWidth / 2,
                y: Double(midY) - scanAreaHeight / 2,
                width: scanAreaWidth,
                height: scanAreaHeight
            )
            if scanAreaOffset != 0 {
                rect = rect.offsetBy(dx: 0, dy: CGFloat(-scanAreaOffset))
            }
            pendingScanRect = rect

            // Apply immediately if the session is already running
            if let session = captureSession, session.isRunning,
               let layer = previewLayer,
               let output = metadataOutput {
                let converted = layer.metadataOutputRectConverted(fromLayerRect: rect)
                sessionQueue.async {
                    output.rectOfInterest = converted
                }
            }
        }

        result(width)
    }

    // MARK: - startScan

    func startScan(_ arguments: Array<Int>, _ result: @escaping FlutterResult) {
        allowedBarcodeTypes = arguments.compactMap { QRCodeTypes[$0] }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.channel.invokeMethod("onPermissionSet", arguments: granted)
            }
            guard granted else { return }
            self.sessionQueue.async {
                do {
                    try self.configureSession()
                    self.captureSession?.startRunning()
                    self.applyPendingScanRect()
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "unknown-error", message: "Unable to start scanning", details: "\(error)"))
                    }
                }
            }
        }
    }

    private func configureSession() throws {
        let session = AVCaptureSession()
        captureSession = session
        session.beginConfiguration()

        guard let device = captureDevice(for: cameraPosition) else {
            throw NSError(domain: "QRScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }
        currentDevice = device
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "QRScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            throw NSError(domain: "QRScanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add metadata output"])
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set supported types after adding output to session
        let requested = allowedBarcodeTypes.isEmpty
            ? output.availableMetadataObjectTypes
            : allowedBarcodeTypes.filter { output.availableMetadataObjectTypes.contains($0) }
        output.metadataObjectTypes = requested
        metadataOutput = output

        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            layer.frame = self.previewView.bounds
            self.previewView.layer.insertSublayer(layer, at: 0)
        }
    }

    private func applyPendingScanRect() {
        guard let rect = pendingScanRect,
              let layer = previewLayer,
              let output = metadataOutput else { return }
        DispatchQueue.main.async {
            let converted = layer.metadataOutputRectConverted(fromLayerRect: rect)
            self.sessionQueue.async {
                output.rectOfInterest = converted
            }
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(_ output: AVCaptureMetadataOutput,
                                didOutput metadataObjects: [AVMetadataObject],
                                from connection: AVCaptureConnection) {
        for obj in metadataObjects {
            guard let readable = obj as? AVMetadataMachineReadableCodeObject else { continue }

            let typeString: String
            switch readable.type {
            case .aztec:             typeString = "AZTEC"
            case .code39:            typeString = "CODE_39"
            case .code93:            typeString = "CODE_93"
            case .code128:           typeString = "CODE_128"
            case .dataMatrix:        typeString = "DATA_MATRIX"
            case .ean8:              typeString = "EAN_8"
            case .ean13:             typeString = "EAN_13"
            case .itf14,
                 .interleaved2of5:   typeString = "ITF"
            case .pdf417:            typeString = "PDF_417"
            case .qr:                typeString = "QR_CODE"
            case .upce:              typeString = "UPC_E"
            default:                 continue
            }

            let bytes: Data? = {
                switch readable.descriptor {
                case let d as CIQRCodeDescriptor:       return d.errorCorrectedPayload
                case let d as CIAztecCodeDescriptor:    return d.errorCorrectedPayload
                case let d as CIPDF417CodeDescriptor:   return d.errorCorrectedPayload
                case let d as CIDataMatrixCodeDescriptor: return d.errorCorrectedPayload
                default: return nil
                }
            }()

            let payload: [String: Any]?
            if let str = readable.stringValue {
                if let b = bytes {
                    payload = ["code": str, "type": typeString, "rawBytes": b]
                } else {
                    payload = ["code": str, "type": typeString]
                }
            } else if let b = bytes {
                payload = ["type": typeString, "rawBytes": b]
            } else {
                payload = nil
            }

            guard let p = payload else { continue }

            if allowedBarcodeTypes.isEmpty || allowedBarcodeTypes.contains(readable.type) {
                channel.invokeMethod("onRecognizeQR", arguments: p)
            }
        }
    }

    // MARK: - Camera controls

    func stopCamera(_ result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        result(nil)
    }

    func pauseCamera(_ result: @escaping FlutterResult) {
        guard captureSession != nil else {
            return result(FlutterError(code: "404", message: "No barcode scanner found", details: nil))
        }
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        result(true)
    }

    func resumeCamera(_ result: @escaping FlutterResult) {
        guard captureSession != nil else {
            return result(FlutterError(code: "404", message: "No barcode scanner found", details: nil))
        }
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
        }
        result(true)
    }

    func getCameraInfo(_ result: @escaping FlutterResult) {
        result(channelValue(from: cameraPosition))
    }

    func flipCamera(_ result: @escaping FlutterResult) {
        guard let session = captureSession else {
            return result(FlutterError(code: "404", message: "No barcode scanner found", details: nil))
        }

        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        guard captureDevice(for: newPosition) != nil else {
            return result(channelValue(from: cameraPosition))
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            session.beginConfiguration()
            // Remove current input
            for input in session.inputs {
                session.removeInput(input)
            }
            // Add new input
            if let device = self.captureDevice(for: newPosition),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                self.currentDevice = device
                self.cameraPosition = newPosition
            }
            session.commitConfiguration()
            DispatchQueue.main.async {
                result(self.channelValue(from: self.cameraPosition))
            }
        }
    }

    // MARK: - Flash / torch

    func getFlashInfo(_ result: @escaping FlutterResult) {
        guard let device = currentDevice else {
            return result(FlutterError(code: "cameraInformationError", message: "Could not get flash information", details: nil))
        }
        result(device.torchMode == .on)
    }

    func toggleFlash(_ result: @escaping FlutterResult) {
        guard let device = currentDevice else {
            return result(FlutterError(code: "404", message: "No barcode scanner found", details: nil))
        }
        guard device.hasTorch && device.isTorchAvailable else {
            return result(FlutterError(code: "404", message: "This device doesn't support flash", details: nil))
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            device.unlockForConfiguration()
            result(device.torchMode == .on)
        } catch {
            result(FlutterError(code: "404", message: "Could not toggle flash", details: "\(error)"))
        }
    }

    // MARK: - System features

    func getSystemFeatures(_ result: @escaping FlutterResult) {
        guard let device = currentDevice else {
            return result(FlutterError(code: "404", message: nil, details: nil))
        }
        let hasBack  = captureDevice(for: .back)  != nil
        let hasFront = captureDevice(for: .front) != nil
        result([
            "hasFrontCamera": hasFront,
            "hasBackCamera":  hasBack,
            "hasFlash":       device.hasTorch && device.isTorchAvailable,
            "activeCamera":   channelValue(from: cameraPosition)
        ])
    }

    // MARK: - Helpers

    private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }
}
```

- [ ] **Step 2: Verify the file compiles (no Xcode build needed yet — check for obvious import errors)**

Open `ios/Classes/QRView.swift` and confirm:
- The `import MTBBarcodeScanner` line is gone
- `import AVFoundation` and `import Flutter` are present
- No references to `MTBBarcodeScanner`, `MTBCamera`, or `MTBTorchMode` remain

Run a grep to confirm:
```bash
grep -n "MTB" ios/Classes/QRView.swift
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add ios/Classes/QRView.swift
git commit -m "feat(ios): replace MTBBarcodeScanner with native AVFoundation"
```

---

### Task 2: Add Package.swift

**Files:**
- Create: `ios/Package.swift`

- [ ] **Step 1: Create `ios/Package.swift` with the following content**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "qr_code_scanner",
    platforms: [
        .iOS(.v16)
    ],
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

- [ ] **Step 2: Verify the target path is correct**

```bash
ls ios/Classes/
```

Expected output includes: `FlutterQrPlugin.h`, `FlutterQrPlugin.m`, `QRView.swift`, `QRViewFactory.swift`, `SwiftFlutterQrPlugin.swift`

- [ ] **Step 3: Commit**

```bash
git add ios/Package.swift
git commit -m "feat(ios): add Package.swift for Swift Package Manager support"
```

---

### Task 3: Update podspec

**Files:**
- Modify: `ios/qr_code_scanner.podspec`

- [ ] **Step 1: Open `ios/qr_code_scanner.podspec` and make the following three changes**

Remove this line:
```ruby
  s.dependency 'MTBBarcodeScanner'
```

Change deployment target from:
```ruby
  s.ios.deployment_target = '8.0'
```
to:
```ruby
  s.ios.deployment_target = '16.1'
```

Change swift version from:
```ruby
  s.swift_version = '4.0'
```
to:
```ruby
  s.swift_version = '5.9'
```

The final podspec should look like:
```ruby
Pod::Spec.new do |s|
  s.name             = 'qr_code_scanner'
  s.version          = '0.2.0'
  s.summary          = 'QR Code Scanner for flutter.'
  s.description      = <<-DESC
A new Flutter project.
                       DESC
  s.homepage         = 'https://github.com/juliuscanute/qr_code_scanner'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'juliuscanute[*]touchcapture.net' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.ios.deployment_target = '16.1'
  s.swift_version = '5.9'
end
```

- [ ] **Step 2: Verify MTBBarcodeScanner is gone**

```bash
grep -n "MTB" ios/qr_code_scanner.podspec
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add ios/qr_code_scanner.podspec
git commit -m "chore(ios): remove MTBBarcodeScanner dep, raise deployment target to 16.1"
```

---

### Task 4: Verify example app builds

**Files:** No changes — read-only verification.

- [ ] **Step 1: Confirm the example app's Podfile does not hardcode MTBBarcodeScanner**

```bash
grep -rn "MTBBarcodeScanner" example/
```
Expected: no output.

- [ ] **Step 2: Install pods for the example app**

```bash
cd example/ios && pod install --repo-update
```

Expected: Resolves without `MTBBarcodeScanner`. No errors.

- [ ] **Step 3: Build the example app for simulator**

```bash
cd example && flutter build ios --simulator --no-codesign
```

Expected: Build succeeds with exit code 0. No compiler errors referencing `MTBBarcodeScanner` or missing symbols.

- [ ] **Step 4: If build fails, check for any remaining MTBBarcodeScanner references in the whole repo**

```bash
grep -rn "MTBBarcodeScanner" .
```

Fix any remaining references, then re-run Step 3.

- [ ] **Step 5: Commit a final verification note (only if any files were changed in Step 4)**

```bash
git add -p
git commit -m "fix(ios): remove remaining MTBBarcodeScanner references"
```
