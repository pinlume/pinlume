import Foundation

/// Snapshot taken before asynchronous clipboard encoding begins. A result may
/// only replace the pasteboard when it is still this process's newest request
/// and no other application has changed the pasteboard in the meantime.
struct ClipboardCommitGate: Equatable {
    let generation: Int
    let pasteboardChangeCount: Int

    func permitsCommit(currentGeneration: Int, currentPasteboardChangeCount: Int) -> Bool {
        generation == currentGeneration && pasteboardChangeCount == currentPasteboardChangeCount
    }
}
