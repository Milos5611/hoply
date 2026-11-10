import AgentKit
import Foundation

struct StateSpanTracker {
    struct Open {
        var id: Int64
        var state: SessionState
        var start: Date
    }

    var open: [SessionKey: Open] = [:]
    var lastPrune = Date.distantPast
}

extension Store {
    public static let stateSpanRetention: TimeInterval = 30 * 86_400
    public static let stateSpanPruneInterval: TimeInterval = 86_400
    public static let shortestStateSpan: TimeInterval = 1

    public func recordStateChanges(_ changes: [StateChange], now: Date = Date()) throws {
        guard !changes.isEmpty else { return }
        try writeSpans {
            for change in changes {
                try enter(change.to, for: change.session.key, at: change.session.stateSince)
            }
            if now.timeIntervalSince(spans.lastPrune) >= Self.stateSpanPruneInterval {
                try Self.pruneStateSpans(db, now: now)
                spans.lastPrune = now
            }
        }
    }

    public func trackStateSpans(of sessions: [AgentSession]) throws {
        let unknown = sessions.filter { spans.open[$0.key] == nil && $0.state != .ended }
        guard !unknown.isEmpty else { return }
        try writeSpans {
            for session in unknown {
                let start = session.stateSince.timeIntervalSince1970
                // The row this run or the last one already wrote for the same stretch is reopened, not doubled.
                if let id = try db.queryOne("""
                    SELECT id FROM state_spans WHERE source = ? AND session_id = ? AND state = ? AND start_at = ?
                    ORDER BY id DESC LIMIT 1
                    """, [session.key.source.rawValue, session.key.id, session.state.rawValue, start], { $0.int64(0) }) {
                    try db.run("UPDATE state_spans SET end_at = NULL WHERE id = ?", [id])
                    spans.open[session.key] = .init(id: id, state: session.state, start: session.stateSince)
                } else {
                    try enter(session.state, for: session.key, at: session.stateSince)
                }
            }
        }
    }

    public func closeStateSpans(for keys: [SessionKey], at time: Date = Date()) throws {
        guard !keys.isEmpty else { return }
        try writeSpans {
            for key in keys {
                try db.run("""
                    UPDATE state_spans SET end_at = max(start_at, ?) WHERE source = ? AND session_id = ? AND end_at IS NULL
                    """, [time.timeIntervalSince1970, key.source.rawValue, key.id])
                spans.open[key] = nil
            }
        }
    }

    public func closeAllStateSpans(at time: Date = Date()) throws {
        try writeSpans {
            try db.run("UPDATE state_spans SET end_at = max(start_at, ?) WHERE end_at IS NULL", [time.timeIntervalSince1970])
            spans.open = [:]
        }
    }

    @discardableResult
    public func pruneStateSpans(now: Date = Date()) throws -> Int {
        spans.lastPrune = now
        return try Self.pruneStateSpans(db, now: now)
    }

    private func writeSpans(_ body: () throws -> Void) throws {
        let saved = spans
        do {
            try db.transaction(body)
        } catch {
            spans = saved
            throw error
        }
    }

    private func enter(_ state: SessionState, for key: SessionKey, at time: Date) throws {
        if let open = spans.open[key] {
            if open.state == state { return }
            if state != .ended, time.timeIntervalSince(open.start) < Self.shortestStateSpan {
                try db.run("UPDATE state_spans SET state = ? WHERE id = ?", [state.rawValue, open.id])
                spans.open[key]?.state = state
                return
            }
            try db.run("UPDATE state_spans SET end_at = max(start_at, ?) WHERE id = ?",
                       [time.timeIntervalSince1970, open.id])
            spans.open[key] = nil
        } else {
            try db.run("""
                UPDATE state_spans SET end_at = max(start_at, ?) WHERE source = ? AND session_id = ? AND end_at IS NULL
                """, [time.timeIntervalSince1970, key.source.rawValue, key.id])
        }
        guard state != .ended else { return }
        let id = try db.queryOne("""
            INSERT INTO state_spans (source, session_id, state, start_at) VALUES (?, ?, ?, ?) RETURNING id
            """, [key.source.rawValue, key.id, state.rawValue, time.timeIntervalSince1970]) { $0.int64(0) }
        if let id { spans.open[key] = .init(id: id, state: state, start: time) }
    }

    @discardableResult
    static func pruneStateSpans(_ db: SQLiteConnection, now: Date) throws -> Int {
        try db.run("DELETE FROM state_spans WHERE end_at IS NOT NULL AND end_at < ?",
                   [now.timeIntervalSince1970 - stateSpanRetention])
        return db.changes
    }

    // Nobody saw the previous run end, so its open spans stop at the last moment the ledger shows Hoply alive.
    static func closeLeftoverStateSpans(_ db: SQLiteConnection, now: Date) throws {
        guard try db.queryOne("SELECT 1 FROM state_spans WHERE end_at IS NULL LIMIT 1", [], { _ in true }) == true else {
            try pruneStateSpans(db, now: now)
            return
        }
        let lastSeen = try db.queryOne("""
            SELECT max(COALESCE((SELECT MAX(max(start_at, COALESCE(end_at, start_at))) FROM state_spans), 0),
                       COALESCE((SELECT MAX(ts) FROM limit_samples), 0),
                       COALESCE((SELECT MAX(last_at) FROM sessions), 0))
            """) { $0.double(0) } ?? 0
        try db.run("UPDATE state_spans SET end_at = max(start_at, ?) WHERE end_at IS NULL",
                   [min(lastSeen, now.timeIntervalSince1970)])
        try pruneStateSpans(db, now: now)
    }
}

extension StoreReader {
    public func stateSpans(of key: SessionKey, coalesced: Bool = true) throws -> [StateSpan] {
        let spans = try db.query("""
            SELECT state, start_at, end_at FROM state_spans WHERE source = ? AND session_id = ? ORDER BY start_at, id
            """, [key.source.rawValue, key.id]) { row -> StateSpan? in
            guard let state = SessionState(rawValue: row.text(0)) else { return nil }
            return StateSpan(state: state, start: Date(timeIntervalSince1970: row.double(1)),
                             end: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)))
        }.compactMap { $0 }
        return coalesced ? StateSpan.coalesced(spans) : spans
    }
}
