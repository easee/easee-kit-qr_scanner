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

    var registrar: FlutterPluginRegistrar
    var channel: FlutterMethodChannel

    // Channel integer (0=back, 1=front) → AVCaptureDevice.Position
    private static func avPosition(from channelValue: Int) -> AVCaptureDevice.Position {
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
        self.cameraPosition = QRView.avPosition(from: facingRaw)
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

            if let session = captureSession, session.isRunning,
               let layer = previewLayer,
               let output = metadataOutput {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    layer.frame = self.previewView.bounds
                    let converted = layer.metadataOutputRectConverted(fromLayerRect: rect)
                    self.sessionQueue.async {
                        output.rectOfInterest = converted
                    }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.previewLayer?.frame = self.previewView.bounds
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.previewLayer?.frame = self.previewView.bounds
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
            guard granted else {
                DispatchQueue.main.async {
                    result(nil)
                }
                return
            }
            self.sessionQueue.async {
                do {
                    try self.configureSession()
                    self.captureSession?.startRunning()
                    self.applyPendingScanRect()
                    DispatchQueue.main.async {
                        result(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "unknown-error", message: "Unable to start scanning", details: "\(error)"))
                    }
                }
            }
        }
    }

    private func configureSession() throws {
        // Tear down any existing session before reconfiguring
        if let existing = captureSession {
            existing.stopRunning()
            captureSession = nil
            metadataOutput = nil
            currentDevice = nil
        }
        let oldLayer = previewLayer
        previewLayer = nil
        DispatchQueue.main.async {
            oldLayer?.removeFromSuperlayer()
        }
        let session = AVCaptureSession()
        captureSession = session
        session.beginConfiguration()
        defer { session.commitConfiguration() }

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
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let session = self.captureSession else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "404", message: "No barcode scanner found", details: nil))
                }
                return
            }
            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            guard let device = self.captureDevice(for: newPosition) else {
                let current = self.channelValue(from: self.cameraPosition)
                DispatchQueue.main.async {
                    result(current)
                }
                return
            }
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            if let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                self.currentDevice = device
                self.cameraPosition = newPosition
            }
            session.commitConfiguration()
            let updated = self.channelValue(from: self.cameraPosition)
            DispatchQueue.main.async {
                result(updated)
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
