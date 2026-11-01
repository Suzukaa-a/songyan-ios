import Foundation
import KeyboardCore
import PackageManager

/// Roots of the host app's private stores (never shared with the keyboard through the App Group).
enum HostStorePaths {
    /// Falls back to Library, never Documents: Documents is listed in the Files app.
    static var applicationSupport: URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
    }
    /// The user's Rime files; Documents is shown in the Files app under the app's name.
    static var rimeConfig: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RimeConfigFolder.name, isDirectory: true)
    }
    /// What the app knows about those files (which replace a package file, which scripts the user agreed to);
    /// private, because any app the user lets into the folder can write the files themselves.
    static var rimeConfigState: URL {
        applicationSupport.appendingPathComponent("RimeConfigState", isDirectory: true)
    }
}

extension HostStorePaths {
    /// File-size text for UI ("1.2 MB").
    static func fileSizeText(_ bytes: some BinaryInteger) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// On-disk diagnostic log of the host app (Application Support/host.log), shown under Settings > Advanced.
///
/// Callers only enqueue; `DiskLogWriter` writes on its own serial queue, so logging from the
/// main actor never blocks on file I/O.
enum HostLog {
    nonisolated static func append(_ line: String) {
        writer.append(line, to: url)
    }

    static func recent() async -> String? {
        await writer.tail(url)
    }

    static func clear() async -> Bool {
        await writer.clear(url)
    }

    private nonisolated static let writer = DiskLogWriter()
    private nonisolated static let url: URL? = {
        // Earlier builds logged into Documents, which the Files app now lists; drop that copy once.
        if let old = DiskLogWriter.documentsLogURL(named: "host.log") {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: old.appendingPathExtension("previous"))
            }
        }
        return HostStorePaths.applicationSupport.appendingPathComponent("host.log")
    }()
}
