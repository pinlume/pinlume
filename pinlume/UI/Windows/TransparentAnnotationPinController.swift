import Cocoa
import os.log

/// Ownership adapter for the transparent Pin lifecycle. Rendering, dragging,
/// focus and Retina geometry remain in PinWindowController. Editing is always
/// reopened in the original transparent selection session, never performed in
/// the compact translated Pin preview.
@MainActor
final class TransparentAnnotationPinController: PinWindowControllerDelegate {

    var onClose: (() -> Void)?

    private var payload: TransparentAnnotationPinPayload
    private var pin: PinWindowController
    private var editingSession: TransparentAnnotationSessionController?
    private var isReplacingPin = false
    private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "transparent-annotation-pin")

    init(payload: TransparentAnnotationPinPayload) {
        self.payload = payload
        pin = PinWindowController(transparentAnnotation: payload)
        bindPin()
    }

    func show() {
        pin.show()
    }

    func close() {
        if let editingSession {
            self.editingSession = nil
            editingSession.onCancel = nil
            editingSession.cancel()
        }
        pin.close()
    }

    func pinWindowDidSelect(_: PinWindowController) {
        pin.setSelected(true)
    }

    private func bindPin() {
        pin.delegate = self
        pin.onRequestTransparentAnnotationEdit = { [weak self] in
            self?.beginReedit()
        }
    }

    private func beginReedit() {
        if let editingSession {
            editingSession.focus()
            return
        }
        let editingPayload = TransparentAnnotationGeometry.payloadPositioned(
            atCompactPinOrigin: pin.transparentVisualFrame.origin,
            from: payload
        )
        payload = editingPayload
        pin.setTemporarilyHidden(true)
        let session = TransparentAnnotationSessionController(editing: editingPayload)
        session.onFinish = { [weak self] payload in
            self?.finishReedit(payload)
        }
        session.onCancel = { [weak self] in
            self?.cancelReedit()
        }
        editingSession = session
        session.show()
        log.debug("reedit begin crop=\(self.payload.cropRect.debugDescription, privacy: .public) origin=\(self.pin.transparentVisualFrame.origin.debugDescription, privacy: .public)")
    }

    private func finishReedit(_ payload: TransparentAnnotationPinPayload) {
        editingSession = nil
        self.payload = payload
        isReplacingPin = true
        pin.close()
        isReplacingPin = false
        pin = PinWindowController(transparentAnnotation: payload)
        bindPin()
        pin.show()
        log.debug("reedit replaced crop=\(payload.cropRect.debugDescription, privacy: .public)")
    }

    private func cancelReedit() {
        editingSession = nil
        pin.setTemporarilyHidden(false)
        log.debug("reedit cancelled")
    }

    func pinWindowDidClose(_: PinWindowController) {
        if !isReplacingPin {
            onClose?()
        }
    }
}
