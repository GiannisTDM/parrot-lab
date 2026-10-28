import AppKit
import CryptoKit

/// Discoverability gate only. Device identity, consent and provenance remain mandatory.
/// Retained by the address field's owner; never saved in preferences or diagnostics.
final class SC3MaintenanceAccess: NSObject, NSTextFieldDelegate {
    var onUnlock: (() -> Void)?
    private var previousAddress: String
    init(address: String) { previousAddress = address }

    private static func matches(_ value: String) -> Bool {
        guard value.utf8.count == 4 else { return false }
        let digest: [UInt8] = [254, 212, 25, 147, 87, 33, 77, 251, 148, 114, 65, 118, 198, 138, 118, 105,
                              141, 188, 60, 45, 54, 49, 122, 137, 83, 32, 32, 122, 201, 16, 222, 166]
        return Array(SHA256.hash(data: Data(value.utf8))) == digest
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, !Self.matches(field.stringValue) else { return }
        previousAddress = field.stringValue
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, Self.matches(field.stringValue) else { return }
        field.stringValue = previousAddress
        onUnlock?()
    }
    static func selfTest() -> Bool {
        let field = NSTextField(string: "192.168.53.1")
        let gate = SC3MaintenanceAccess(address: field.stringValue)
        var calls = 0; gate.onUnlock = { calls += 1 }
        let token = String(bytes: [82, 79, 79, 84], encoding: .utf8)!
        gate.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        for text in ["192.168.2.1", token.lowercased(), String(token.dropLast()), " " + token, token + " "] {
            field.stringValue = text
            gate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            guard calls == 0, field.stringValue == text else { return false }
        }
        field.stringValue = token
        gate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        guard calls == 1, field.stringValue == "192.168.53.1" else { return false }
        field.stringValue = "192.168.2.1"
        gate.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = token
        gate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        return calls == 2 && field.stringValue == "192.168.2.1"
    }
}
