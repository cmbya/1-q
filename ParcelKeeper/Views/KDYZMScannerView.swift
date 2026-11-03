import SwiftUI
import AVFoundation
import UIKit

// All capture configuration/start/stop/delegate work is serialized off the main thread.
// Permission continuations are weak and cannot restart a closed/dismissed session.
private final class KDYZMCameraEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.dinghao.ParcelKeeper.pairing-camera")
    private var wanted = false
    private var closed = false
    private var configured = false
    private var delivered = false
    var completion: ((Result<KDYZMPairingPayload, Error>) -> Void)?
    var unavailable: ((String) -> Void)?

    func resume() {
        queue.async { [weak self] in
            guard let self, !self.closed, !self.delivered else { return }
            self.wanted = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.startIfWanted()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, self.wanted, !self.closed else { return }
                        if granted { self.startIfWanted() }
                        else { self.report("相机权限未开启。请在系统设置中允许相机，或取消后手动填写。") }
                    }
                }
            default: self.report("相机权限未开启。请在系统设置中允许相机，或取消后手动填写。")
            }
        }
    }

    func pause(close: Bool = false) {
        // Bounded strong cleanup guarantees stop even when the controller is released.
        queue.async { [self] in
            self.wanted = false
            self.closed = self.closed || close
            if self.session.isRunning { self.session.stopRunning() }
            if close {
                self.session.beginConfiguration()
                for output in self.session.outputs { self.session.removeOutput(output) }
                for input in self.session.inputs { self.session.removeInput(input) }
                self.session.commitConfiguration()
            }
        }
    }

    private func startIfWanted() {
        guard wanted, !closed, !delivered else { return }
        if !configured {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                report("相机不可用，请取消后手动填写地址和绑定码。"); return
            }
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration(); report("无法打开相机，请使用手动填写。"); return
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.removeInput(input); session.commitConfiguration()
                report("设备不支持二维码扫描，请使用手动填写。"); return
            }
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.removeOutput(output); session.removeInput(input); session.commitConfiguration()
                report("设备不支持二维码扫描，请使用手动填写。"); return
            }
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        if !session.isRunning { report("相机启动失败，请取消后重试或手动填写。") }
    }

    private func report(_ text: String) {
        guard wanted, !closed else { return }
        unavailable?(text) // caller hops to main, never includes camera/QR raw errors
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard wanted, !closed, !delivered else { return }
        let codes = metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }.filter { $0.type == .qr }
        guard !codes.isEmpty else { return }
        delivered = true
        wanted = false
        if session.isRunning { session.stopRunning() }
        let result = Result { () throws -> KDYZMPairingPayload in
            guard codes.count == 1 else { throw KDYZMPairingScanError.multipleCodes }
            return try KDYZMPairingPayload.single(codes.compactMap(\.stringValue))
        }
        completion?(result)
    }
}

private final class KDYZMCameraController: UIViewController {
    private let engine = KDYZMCameraEngine()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var usable = true
    private var active = false
    var onResult: ((Result<KDYZMPairingPayload, Error>) -> Void)?
    var onUnavailable: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: engine.session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: engine.session)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: engine.session)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeError), name: AVCaptureSession.runtimeErrorNotification, object: engine.session)
        engine.completion = { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.usable else { return }
                self.usable = false
                self.onResult?(result)
            }
        }
        engine.unavailable = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.usable else { return }
                self.onUnavailable?(text)
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    // Capture notifications may arrive off-main; never touch UIKit there.
    @objc nonisolated private func interrupted() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.usable else { return }
            self.onUnavailable?("相机暂时被系统中断，恢复后可继续扫描，或取消后手动填写。")
        }
    }
    @objc nonisolated private func interruptionEnded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.usable, self.active else { return }
            self.engine.resume()
        }
    }
    @objc nonisolated private func runtimeError() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.usable else { return }
            self.onUnavailable?("相机运行失败，请取消后重新扫描或手动填写。")
            self.close()
        }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if active, usable { engine.resume() } else { engine.pause() }
    }
    func close() {
        usable = false
        active = false
        NotificationCenter.default.removeObserver(self)
        onResult = nil; onUnavailable = nil
        engine.pause(close: true)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        close()
    }
}

private struct KDYZMCameraSurface: UIViewControllerRepresentable {
    let active: Bool
    let onResult: (Result<KDYZMPairingPayload, Error>) -> Void
    let onUnavailable: (String) -> Void
    func makeUIViewController(context: Context) -> KDYZMCameraController {
        let controller = KDYZMCameraController()
        controller.onResult = onResult
        controller.onUnavailable = onUnavailable
        controller.loadViewIfNeeded()
        return controller
    }
    func updateUIViewController(_ controller: KDYZMCameraController, context: Context) {
        controller.setActive(active)
    }
    static func dismantleUIViewController(_ controller: KDYZMCameraController, coordinator: ()) {
        controller.close()
    }
}

struct KDYZMScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var message: String?
    @State private var finished = false
    let onScan: (KDYZMPairingPayload) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                Text("只扫描后台生成的绑定二维码。识别后先确认 HTTPS 地址，不会自动访问或兑换。")
                    .font(.footnote).padding()
                KDYZMCameraSurface(active: scenePhase == .active && !finished, onResult: { result in
                    guard !finished else { return }
                    finished = true
                    guard scenePhase == .active else {
                        message = "扫描期间应用已进入后台，本次结果已丢弃；请取消后重新扫描。"
                        return
                    }
                    switch result {
                    case .success(let payload): onScan(payload); dismiss()
                    case .failure(let error): message = (error as? KDYZMPairingScanError)?.localizedDescription ?? "二维码无效，请取消后重试。"
                    }
                }, onUnavailable: { message = $0 })
                if let message { Text(message).padding().accessibilityLabel(message) }
            }
            .navigationTitle("扫描后台绑定二维码")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("取消") { finished = true; dismiss() }
            } }
        }
        .onDisappear { finished = true }
    }
}
