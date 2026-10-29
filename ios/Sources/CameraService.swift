import AVFoundation
import UIKit

enum CameraError: LocalizedError {
    case permission
    case noDevice(String)
    case configure(String)
    case capture(String)
    case encode
    case busy

    var errorDescription: String? {
        switch self {
        case .permission: return "没有相机权限：去 设置 → 小北冥 → 相机 打开"
        case .noDevice(let p): return "找不到\(p == "front" ? "前置" : "后置")摄像头"
        case .configure(let why): return "相机会话配置失败：\(why)"
        case .capture(let why): return "拍照失败：\(why)"
        case .encode: return "照片编码失败"
        case .busy: return "上一次拍照还没结束"
        }
    }
}

/// 眼睛。前后摄切换 + 拍照输出 JPEG（长边 1280、质量 0.7）+ 手电筒。
///
/// 约束：只有桥接下发的 look 指令会调用 capture；App 自身没有任何定时/后台拍照逻辑。
final class CameraService: NSObject {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "xiaobeiming.camera.session")
    private let lock = NSLock()
    private var input: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var configured = false
    private var pending: CheckedContinuation<(Data, Int, Int), Error>?

    // MARK: - 权限

    func hasPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { ok in cont.resume(returning: ok) }
            }
        default:
            return false
        }
    }

    // MARK: - 会话

    private func configure(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let existing = input {
            session.removeInput(existing)
            input = nil
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            session.commitConfiguration()
            throw CameraError.noDevice(position == .front ? "front" : "back")
        }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                throw CameraError.configure("canAddInput 返回 false")
            }
            session.addInput(newInput)
            input = newInput
        } catch let e as CameraError {
            throw e
        } catch {
            session.commitConfiguration()
            throw CameraError.configure(error.localizedDescription)
        }

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                throw CameraError.configure("canAddOutput 返回 false")
            }
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        currentPosition = position
        configured = true
        if !session.isRunning {
            session.startRunning()
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - 拍照

    /// 返回 (JPEG 数据, 宽, 高)。宽高是缩放后的真实像素尺寸。
    func captureJPEG(camera: String,
                     maxLongSide: CGFloat = 1280,
                     quality: CGFloat = 0.7) async throws -> (Data, Int, Int) {
        guard await requestPermission() else { throw CameraError.permission }
        let position: AVCaptureDevice.Position = (camera == "front") ? .front : .back

        try queue.sync {
            if !configured || currentPosition != position {
                try configure(position: position)
            } else if !session.isRunning {
                session.startRunning()
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int, Int), Error>) in
            lock.lock()
            if pending != nil {
                lock.unlock()
                cont.resume(throwing: CameraError.busy)
                return
            }
            pending = cont
            lock.unlock()

            queue.async { [weak self] in
                guard let self = self else { return }
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                settings.photoQualityPrioritization = .speed
                if #available(iOS 17.0, *),
                   let conn = self.photoOutput.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func finish(_ result: Result<(Data, Int, Int), Error>) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        guard let cont = cont else { return }
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - 手电筒

    @discardableResult
    func setTorch(_ on: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                do {
                    try device.setTorchModeOn(level: 1.0)
                } catch {
                    device.torchMode = .on
                }
            } else {
                device.torchMode = .off
            }
            return true
        } catch {
            return false
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            finish(.failure(CameraError.capture(error.localizedDescription)))
            return
        }
        guard let raw = photo.fileDataRepresentation(), let image = UIImage(data: raw) else {
            finish(.failure(CameraError.encode))
            return
        }
        let scaled = image.downscaled(maxLongSide: 1280)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.7) else {
            finish(.failure(CameraError.encode))
            return
        }
        finish(.success((jpeg, Int(scaled.size.width * scaled.scale), Int(scaled.size.height * scaled.scale))))
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error = error {
            finish(.failure(CameraError.capture(error.localizedDescription)))
        }
    }
}

extension UIImage {
    /// 长边缩到指定像素，短边按比例。已经更小就不放大。
    func downscaled(maxLongSide: CGFloat) -> UIImage {
        let w = size.width * scale
        let h = size.height * scale
        let longSide = max(w, h)
        guard longSide > maxLongSide, longSide > 0 else { return self }
        let ratio = maxLongSide / longSide
        let target = CGSize(width: (w * ratio).rounded(), height: (h * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
