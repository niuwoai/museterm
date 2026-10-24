import Foundation

enum TerminalWorkingDirectory {
    static func normalizedExistingDirectory(_ directory: String?) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return nil }
        let expanded: String
        if directory.lowercased().hasPrefix("file:") {
            guard let url = URL(string: directory), url.isFileURL, url.path.hasPrefix("/"),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
            // OSC 7 includes the reporting machine's hostname. Only its local
            // path is used here; this never accesses a network filesystem URL.
            expanded = url.path
        } else { expanded = (directory as NSString).expandingTildeInPath }
        guard !expanded.utf8.contains(0) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return expanded
    }
}
