import Foundation

/// ⌘+点击终端里的链接后要做的事。SwiftTerm 负责识别（OSC 8 显式超链接 +
/// Ghostty 风格的隐式 URL/路径），这里只决定"怎么打开"。
enum TerminalLinkTarget: Equatable {
    /// 普通网页：交给默认浏览器
    case webPage(URL)
    /// 图片地址：下载到临时目录后用默认图片查看器打开（失败时退回浏览器）
    case webImage(URL)
    /// 本机已存在的普通文件或目录：交给默认 App（Markdown 走默认 Markdown 查看器）
    case localItem(URL)
    /// 可执行文件、脚本、App 包等：只在 Finder 中显示，绝不直接运行
    case revealInFinder(URL)
    /// mailto:、ssh:// 等其他 scheme：保持原有行为，交给系统处理
    case otherScheme(URL)
}

enum TerminalLinkResolutionFailure: Error, Equatable {
    /// 远端（SSH）会话里的路径，本机没有对应文件
    case remotePath(String)
    /// 本机找不到该文件
    case notFound(String)
    /// 无法解析成 URL 或路径
    case invalid(String)
}

struct TerminalLinkFileInfo: Equatable {
    let isDirectory: Bool
    let isExecutable: Bool
}

struct TerminalLinkContext {
    /// 当前标签的工作目录（可能是普通路径，也可能是 OSC 7 上报的 file:// URL）
    let currentDirectory: String?
    /// 标签是否连在 SSH 远端
    let isRemoteSession: Bool
}

enum TerminalLinkResolver {
    static let webSchemes: Set<String> = ["http", "https"]

    /// 与 SwiftTerm 隐式识别一致的、不带 `//` 的 scheme
    private static let colonOnlySchemes: Set<String> = ["file", "mailto", "tel", "magnet", "news", "ssh"]

    /// Preview 等系统图片查看器能直接打开的格式。SVG 不在列：新版"预览"不支持，
    /// 下载后通常还是落到浏览器里，不如直接用浏览器打开。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico",
    ]

    /// 用默认 App 打开会直接运行（或安装、加载）的文件类型，一律改为在 Finder 中显示。
    static let revealOnlyExtensions: Set<String> = [
        "app", "appex", "command", "tool", "terminal", "sh", "bash", "zsh", "fish", "csh", "ksh",
        "py", "rb", "pl", "jar", "pkg", "mpkg", "scpt", "scptd", "applescript", "workflow", "action",
        "prefpane", "saver", "kext", "plugin", "webloc", "inetloc", "fileloc", "url",
    ]

    /// grep、编译器输出常见的 `file.md:12` / `file.md:12:5` 行列号后缀
    private static let lineColumnSuffix = try? NSRegularExpression(pattern: #":\d+(?::\d+)?:?$"#)

    static func resolve(
        _ rawLink: String,
        context: TerminalLinkContext,
        homeDirectory: String = NSHomeDirectory(),
        fileInfo: (String) -> TerminalLinkFileInfo? = defaultFileInfo
    ) -> Result<TerminalLinkTarget, TerminalLinkResolutionFailure> {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .failure(.invalid(rawLink)) }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), isRecognizedScheme(scheme, in: link) {
            if webSchemes.contains(scheme) {
                guard url.host?.isEmpty == false else { return .failure(.invalid(link)) }
                return .success(isImageURL(url) ? .webImage(url) : .webPage(url))
            }
            if scheme == "file" {
                return resolvePath(url.path, context: context, homeDirectory: homeDirectory, fileInfo: fileInfo)
            }
            return .success(.otherScheme(url))
        }

        return resolvePath(link, context: context, homeDirectory: homeDirectory, fileInfo: fileInfo)
    }

    /// `README.md:12` 也能被 URL 解析出 scheme `readme.md`，只认 `xxx://` 形式和少数无斜杠 scheme
    private static func isRecognizedScheme(_ scheme: String, in link: String) -> Bool {
        if link.lowercased().hasPrefix(scheme + "://") {
            return true
        }
        return colonOnlySchemes.contains(scheme)
    }

    static func isImageURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func defaultFileInfo(_ path: String) -> TerminalLinkFileInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return TerminalLinkFileInfo(
            isDirectory: isDirectory.boolValue,
            isExecutable: !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        )
    }

    private static func resolvePath(
        _ path: String,
        context: TerminalLinkContext,
        homeDirectory: String,
        fileInfo: (String) -> TerminalLinkFileInfo?
    ) -> Result<TerminalLinkTarget, TerminalLinkResolutionFailure> {
        guard !path.isEmpty else { return .failure(.invalid(path)) }
        // 远端会话里的路径指向远端机器，本机同名文件不是同一个东西，不能乱开
        if context.isRemoteSession {
            return .failure(.remotePath(path))
        }

        for candidate in candidatePaths(for: path) {
            guard let absolute = absolutePath(
                for: candidate,
                currentDirectory: context.currentDirectory,
                homeDirectory: homeDirectory
            ) else { continue }
            guard let info = fileInfo(absolute) else { continue }
            let url = URL(fileURLWithPath: absolute, isDirectory: info.isDirectory)
            return .success(shouldOnlyReveal(url: url, info: info) ? .revealInFinder(url) : .localItem(url))
        }
        return .failure(.notFound(path))
    }

    /// 先按原样找；找不到再去掉 `:行号:列号` 后缀找
    private static func candidatePaths(for path: String) -> [String] {
        var candidates = [path]
        if let regex = lineColumnSuffix {
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            let stripped = regex.stringByReplacingMatches(in: path, range: range, withTemplate: "")
            if !stripped.isEmpty, stripped != path {
                candidates.append(stripped)
            }
        }
        return candidates
    }

    private static func absolutePath(
        for path: String,
        currentDirectory: String?,
        homeDirectory: String
    ) -> String? {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        // `$HOME/...` 之类的变量路径不展开：终端里的变量值与 App 进程的环境不一定一致
        if path.hasPrefix("$") {
            return nil
        }
        guard let base = normalizedDirectory(currentDirectory) else { return nil }
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return nil }
        if let url = URL(string: directory), url.isFileURL {
            return url.path.isEmpty ? nil : url.path
        }
        return (directory as NSString).expandingTildeInPath
    }

    private static func shouldOnlyReveal(url: URL, info: TerminalLinkFileInfo) -> Bool {
        let ext = url.pathExtension.lowercased()
        if revealOnlyExtensions.contains(ext) {
            return true
        }
        // 无扩展名且带可执行位的通常是二进制或脚本，打开即运行
        return info.isExecutable && ext.isEmpty
    }
}

/// SwiftTerm 的隐式识别（沿用 Ghostty 规则）不认不带 `/` 的裸文件名，比如 `ls` 输出里的
/// `CHANGELOG.md`。⌘+点击没命中任何链接时，用这里从点击处取出"像文件名的词"再试一次。
enum TerminalLinkWordExtractor {
    private static let pathCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_.~/:@+%#,="))
    /// 词首的分隔标点（不含 `.`，否则 `../x`、`.env` 会被截坏）
    private static let trimmedLeadingCharacters = CharacterSet(charactersIn: ",:;=")
    /// 词尾的句末标点和 `file.md:12:` 这类多余冒号
    private static let trimmedTrailingCharacters = CharacterSet(charactersIn: ".,:;=")

    /// cells 每个元素对应终端一格；宽字符占位格和空格都视为分隔符
    static func candidate(in cells: [Character], at column: Int) -> String? {
        guard cells.indices.contains(column), isPathCharacter(cells[column]) else { return nil }
        var start = column
        while start > cells.startIndex, isPathCharacter(cells[start - 1]) {
            start -= 1
        }
        var end = column
        while end + 1 < cells.endIndex, isPathCharacter(cells[end + 1]) {
            end += 1
        }
        var scalars = Substring(String(cells[start...end])).unicodeScalars
        while let first = scalars.first, trimmedLeadingCharacters.contains(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, trimmedTrailingCharacters.contains(last) {
            scalars.removeLast()
        }
        let word = String(scalars)
        return word.isEmpty ? nil : word
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { pathCharacters.contains($0) }
    }
}
