import AgentKit
import Foundation

extension CleanupPass {
    static let transcriptExtension = ".jsonl"

    static func sessionFolder(ofTranscript path: String) -> String? {
        path.hasSuffix(transcriptExtension) ? String(path.dropLast(transcriptExtension.count)) : nil
    }

    func transcriptCandidates() -> [CleanupCandidate] {
        var sessions = Set<String>()
        for folder in files.entries(of: inventory.transcriptsDirectory) {
            let folderPath = inventory.transcriptsDirectory + "/" + folder
            for entry in files.entries(of: folderPath) {
                let path = folderPath + "/" + entry
                if let session = Self.sessionFolder(ofTranscript: path) {
                    sessions.insert(session)
                } else if files.isDirectory(path) {
                    sessions.insert(path)
                }
            }
        }
        return sessions.sorted().compactMap { transcriptCandidate(sessionFolder: $0, knownBytes: nil) }
    }

    func refreshedTranscript(_ candidate: CleanupCandidate) -> CleanupCandidate? {
        guard let path = candidate.path else { return nil }
        return transcriptCandidate(sessionFolder: Self.sessionFolder(ofTranscript: path) ?? path,
                                   knownBytes: candidate.bytes)
    }

    // A folder without any transcript in it (Claude's `memory`, for one) is not a session and gives no candidate.
    private func transcriptCandidate(sessionFolder: String, knownBytes: Int64?) -> CleanupCandidate? {
        let main = sessionFolder + Self.transcriptExtension
        let transcripts = [main] + (files.isDirectory(sessionFolder) ? files.transcriptFiles(under: sessionFolder) : [])
        let facts = TranscriptFacts(files: transcripts.compactMap { path in
            FileTailer.status(of: path).map { stat in
                let cursor = inventory.transcriptCursors[path]
                return TranscriptFacts.File(inode: stat.inode, size: stat.size, modified: stat.modified,
                                            ingestedInode: cursor?.inode, ingestedOffset: cursor?.offset)
            }
        })
        guard !facts.files.isEmpty else { return nil }
        let hasMain = files.exists(main)
        let session = inventory.transcriptSessions[main]
        let bytes = knownBytes ?? [main, sessionFolder].compactMap { sizer.allocatedSize(of: $0) }.reduce(0, +)
        return CleanupCandidate(kind: .transcript, path: hasMain ? main : sessionFolder,
                                title: session?.title ?? (sessionFolder as NSString).lastPathComponent,
                                project: session?.project, bytes: bytes, lastActive: facts.lastWritten,
                                keepReasons: rules.keepReasons(for: facts, now: now))
    }
}
