import Foundation
import PIiOSCore

// Public wire structs intentionally expose decoding rather than memberwise
// construction. Keep fixture construction local to the App test target.
extension RACPV2Attachment {
    init(id: String, sessionId: String, kind: String, fileName: String,
         mimeType: String, byteLength: Int, sha256: String, state: String,
         createdAt: String) {
        let object: [String: Any] = [
            "id": id, "sessionId": sessionId, "kind": kind,
            "fileName": fileName, "mimeType": mimeType, "byteLength": byteLength,
            "sha256": sha256, "state": state, "createdAt": createdAt
        ]
        self = try! JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

extension RACPV2AttachmentReadResult {
    init(attachment: RACPV2Attachment, dataBase64: String, eof: Bool) {
        let encoded = try! JSONEncoder().encode(attachment)
        let object: [String: Any] = [
            "attachment": try! JSONSerialization.jsonObject(with: encoded),
            "dataBase64": dataBase64, "eof": eof
        ]
        self = try! JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
