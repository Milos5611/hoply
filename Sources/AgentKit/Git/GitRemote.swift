import Foundation

public enum GitRemote {
    public static func originURL(ofRepoAt root: String, fileSystem fs: some ProjectFileSystem) -> String? {
        let gitPath = root + "/.git"
        if fs.isDirectory(gitPath) { return fs.readText(gitPath + "/config").flatMap { url(inConfig: $0) } }
        guard fs.isFile(gitPath), let text = fs.readText(gitPath),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let gitdir = ProjectResolver.absolute(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces),
                                              relativeTo: root)
        let common = fs.readText(gitdir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configDirectory = common.isEmpty ? gitdir : ProjectResolver.absolute(common, relativeTo: gitdir)
        return fs.readText(configDirectory + "/config").flatMap { url(inConfig: $0) }
    }

    public static func url(inConfig text: String, remote: String = "origin") -> String? {
        var inRemote = false
        var found: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else {
                    inRemote = false
                    continue
                }
                let header = line[line.index(after: line.startIndex)..<close]
                let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let name = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                // Section names are case-insensitive, the quoted subsection is not.
                inRemote = parts.first?.lowercased() == "remote" && name == "\"\(remote)\""
                continue
            }
            guard inRemote, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { found = value }
        }
        return found
    }

    public static func identity(_ url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var host: String
        var path: String
        if let scheme = text.range(of: "://") {
            let name = text[..<scheme.lowerBound].lowercased()
            text = String(text[scheme.upperBound...])
            if name == "file" { return local(text) }
            guard ["ssh", "https", "http", "git", "git+ssh", "ssh+git"].contains(name) else { return nil }
            let slash = text.firstIndex(of: "/") ?? text.endIndex
            host = String(text[..<slash])
            path = String(text[slash...])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        } else if text.hasPrefix("/") {
            return local(text)
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp form: [user@]host:path
            host = String(text[..<colon])
            path = String(text[text.index(after: colon)...])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        } else {
            return nil
        }
        path = trimmed(path)
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host + "/" + path).lowercased()
    }

    private static func local(_ path: String) -> String? {
        let path = trimmed(path)
        return path.isEmpty ? nil : "file:/" + path
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }
}

public struct MergeSuggestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var remote: String
    public var projects: [ProjectRef]

    public init(id: String, remote: String, projects: [ProjectRef]) {
        self.id = id
        self.remote = remote
        self.projects = projects
    }

    public var summary: String {
        let names = projects.map(\.title)
        let list = names.count == 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "\(list) share origin \(remote)"
    }

    public static func clones(_ projects: [(project: ProjectRef, originURL: String)],
                              dismissed: Set<String> = []) -> [MergeSuggestion] {
        var groups: [String: [ProjectRef]] = [:]
        for (project, url) in projects {
            guard let identity = GitRemote.identity(url) else { continue }
            if groups[identity]?.contains(where: { $0.id == project.id }) != true {
                groups[identity, default: []].append(project)
            }
        }
        return groups.keys.sorted().compactMap { identity in
            guard let members = groups[identity], members.count > 1 else { return nil }
            let ids = members.map(\.id).sorted().map(String.init).joined(separator: ",")
            let suggestion = MergeSuggestion(id: "clone:\(identity):\(ids)", remote: identity, projects: members)
            return dismissed.contains(suggestion.id) ? nil : suggestion
        }
    }
}
