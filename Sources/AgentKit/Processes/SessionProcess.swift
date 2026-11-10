import Foundation

public enum SessionProcess {
    public static let maxHops = 6

    public static func agent(reportedPID: Int32, source: AgentSource, reportedAt: Date, uid: UInt32,
                             lineage: ProcessLineage) -> ScannedProcess? {
        // A process that started after the hook fired took over a dead pid.
        guard let reported = lineage.snapshot.process(reportedPID), reported.uid == uid,
              reported.identity.startedAt <= reportedAt.addingTimeInterval(1) else { return nil }
        let chain = [reported] + lineage.ancestors(of: reportedPID).prefix(maxHops)
        return chain.first { $0.uid == uid && ProcessLineage.agentSource(of: $0) == source }
    }
}
