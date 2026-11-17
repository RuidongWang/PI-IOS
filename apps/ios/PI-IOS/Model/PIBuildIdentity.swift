import Foundation
import MachO

/// LC_UUID identifies the linked code, including Xcode's Debug dylib when used.
/// Reads loaded headers only; no startup file I/O or process/environment data.
enum PIBuildIdentity {
    static let current: String = {
        let bundlePath = Bundle.main.bundleURL.path + "/"
        var fallback: UnsafePointer<mach_header>?
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
            let path = String(cString: name)
            if index == 0 { fallback = header }
            if path.hasPrefix(bundlePath), path.hasSuffix(".debug.dylib"), let uuid = imageUUID(header) {
                return uuid
            }
        }
        return fallback.flatMap(imageUUID) ?? "unknown"
    }()

    private static func imageUUID(_ header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let base = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        let size = Int(header.pointee.sizeofcmds)
        var offset = 0
        for _ in 0..<header.pointee.ncmds {
            guard offset + MemoryLayout<load_command>.size <= size else { return nil }
            let pointer = base.advanced(by: offset)
            let command = pointer.load(as: load_command.self)
            let commandSize = Int(command.cmdsize)
            guard commandSize >= MemoryLayout<load_command>.size, offset + commandSize <= size else { return nil }
            if command.cmd == LC_UUID, commandSize >= MemoryLayout<uuid_command>.size {
                return UUID(uuid: pointer.load(as: uuid_command.self).uuid).uuidString.lowercased()
            }
            offset += commandSize
        }
        return nil
    }
}
