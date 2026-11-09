import AgentKit
import Foundation

/// Sample state for `Hoply --snapshot`, shaped like a busy afternoon.
enum PreviewData {
    static var settings: AppSettings {
        var settings = AppSettings()
        settings.vllmBaseURL = "http://zgx.local:8000"
        settings.vllmName = "ZGX"
        settings.claudeLimitsEnabled = true
        return settings
    }

    static func events(now: Date) -> [AgentEvent] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func key(_ source: AgentSource, _ id: String) -> SessionKey { SessionKey(source: source, id: id) }
        let auth = key(.claudeCode, "auth")
        let orders = key(.copilotCLI, "orders")
        let tests = key(.qwenCode, "tests")
        let pricing = key(.claudeCode, "pricing")
        let docs = key(.claudeCode, "docs")
        let home = NSHomeDirectory()
        return [
            AgentEvent(key: auth, kind: .promptSubmitted("Refactor the auth middleware to use refresh tokens"),
                       time: at(46), cwd: "\(home)/Project/fiba", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: auth, kind: .usage(.init(inputTokens: 21_000, outputTokens: 9_000, cacheTokens: 24_000, costUSD: 0.21)),
                       time: at(5), fromHook: false),
            AgentEvent(key: auth, kind: .turnFinished("Middleware now refreshes tokens; all 214 tests pass."),
                       time: at(4), fromHook: true),
            AgentEvent(key: orders, kind: .promptSubmitted("Add pagination to the orders endpoint"),
                       time: at(12), cwd: "\(home)/Project/yasm-backend", fromHook: true),
            AgentEvent(key: orders, kind: .needsPermission("Run `dotnet test` in yasm-backend?"),
                       time: at(1), fromHook: true),
            AgentEvent(key: pricing, kind: .promptSubmitted("Build the pricing section"),
                       time: at(42), cwd: "\(home)/Project/fiba", model: "claude-sonnet-5", fromHook: true),
            AgentEvent(key: pricing, kind: .toolStarted("Edit"), time: at(0.2), fromHook: true),
            AgentEvent(key: pricing, kind: .usage(.init(inputTokens: 80_000, outputTokens: 30_000, cacheTokens: 300_000, costUSD: 0.64)),
                       time: at(0.5), fromHook: false),
            AgentEvent(key: tests, kind: .promptSubmitted("Write unit tests for the Prometheus parser"),
                       time: at(6), cwd: "\(home)/Project/hoply", model: "qwen3-coder", fromHook: false),
            AgentEvent(key: tests, kind: .usage(.init(inputTokens: 2_100, outputTokens: 900)), time: at(0.3), fromHook: false),
            AgentEvent(key: docs, kind: .promptSubmitted("Update the README for v2"),
                       time: at(30), cwd: "\(home)/Project/hoply", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: docs, kind: .sessionEnded(nil), time: at(8), fromHook: true),
        ]
    }

    static func activity(now: Date) -> RollingSeries {
        series(now: now, values: [1, 0, 2, 3, 1, 4, 6, 3, 2, 5, 7, 4, 3, 6, 8, 5, 9, 7, 11, 8], max: false)
    }

    static func throughput(now: Date) -> RollingSeries {
        series(now: now, values: [0, 0, 12, 38, 41, 40, 22, 0, 0, 35, 44, 43, 39, 30, 41, 45, 44, 38, 42, 43], max: true)
    }

    static func vllm(now: Date) -> VLLMStatus {
        func snapshot(generated: Double, at time: Date) -> VLLMSnapshot {
            let text = """
            vllm:num_requests_running{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 2
            vllm:num_requests_waiting{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 1
            vllm:kv_cache_usage_perc{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 0.44
            vllm:prompt_tokens_total{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} 120000
            vllm:generation_tokens_total{model_name="Qwen/Qwen3-Coder-30B-A3B-Instruct"} \(generated)
            """
            return VLLMSnapshot.from(samples: PrometheusParser.parse(text), at: time)
        }
        return VLLMStatus.compute(previous: snapshot(generated: 45_000, at: now.addingTimeInterval(-5)),
                                  current: snapshot(generated: 45_215, at: now))
    }

    static func claudeLimits(now: Date) -> ClaudeLimits? {
        let fiveHour = Int(now.addingTimeInterval(2.6 * 3_600).timeIntervalSince1970)
        let week = Int(now.addingTimeInterval(3.7 * 86_400).timeIntervalSince1970)
        let json = #"{"five_hour":{"utilization":62,"resets_at":\#(fiveHour)},"seven_day":{"utilization":25,"resets_at":\#(week)}}"#
        return try? ClaudeLimits.decode(Data(json.utf8))
    }

    private static func series(now: Date, values: [Double], max: Bool) -> RollingSeries {
        var series = RollingSeries(bucketLength: 30, capacity: values.count, now: now)
        for (index, value) in values.enumerated() {
            let time = now.addingTimeInterval(-Double(values.count - 1 - index) * 30)
            if max { series.recordMax(value, at: time) } else { series.add(value, at: time) }
        }
        return series
    }
}
