import Foundation

enum BundledPricing {
    static let json = #"""
    {
      "webSearchPerThousand": 10,
      "models": {
        "claude-fable-5-1": { "input": 10, "output": 50, "cacheRead": 0.25 },
        "claude-mythos-5-1": { "input": 10, "output": 50, "cacheRead": 0.25 },
        "claude-fable-5": { "input": 10, "output": 50, "cacheRead": 1.0 },
        "claude-mythos-5": { "input": 10, "output": 50, "cacheRead": 1.0 },
        "claude-opus-5-5": { "input": 4, "output": 20, "cacheRead": 0.2, "fast": { "input": 8, "output": 40 } },
        "claude-opus-5": { "input": 5, "output": 25, "fast": { "input": 10, "output": 50 } },
        "claude-opus-4-8": { "input": 5, "output": 25, "fast": { "input": 10, "output": 50 } },
        "claude-opus-4-7": { "input": 5, "output": 25 },
        "claude-opus-4-6": { "input": 5, "output": 25 },
        "claude-sonnet-5-5": { "input": 2, "output": 10, "cacheRead": 0.2 },
        "claude-sonnet-5": { "input": 2, "output": 10 },
        "claude-sonnet-4-6": { "input": 3, "output": 15 },
        "claude-haiku-5-5": { "input": 0.1, "output": 0.5, "longContext": { "above": 100000, "input": 0.5, "output": 2.5 } },
        "claude-haiku-4-5": { "input": 1, "output": 5 },
        "gpt-6-astra": { "input": 10, "output": 50, "cacheRead": 1, "cacheWrite5m": 12.5, "cacheWrite1h": 25, "longContext": { "above": 272000, "input": 20, "output": 75 } },
        "gpt-6.1-sol": { "input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite5m": 2.5, "cacheWrite1h": 5, "longContext": { "above": 272000, "input": 4, "output": 15 } },
        "gpt-6.1-terra": { "input": 1, "output": 5, "cacheRead": 0.05, "cacheWrite5m": 1.25, "cacheWrite1h": 2.5, "longContext": { "above": 272000, "input": 2, "output": 7.5 } },
        "gpt-6-sol": { "input": 2, "output": 10, "cacheRead": 0.2, "cacheWrite5m": 2.5, "cacheWrite1h": 5, "longContext": { "above": 272000, "input": 4, "output": 15 } },
        "gpt-6-luna": { "input": 0.1, "output": 0.5, "cacheRead": 0.01, "cacheWrite5m": 0.125, "cacheWrite1h": 0.25, "longContext": { "above": 272000, "input": 0.2, "output": 0.75 } },
        "gpt-5.6-sol": { "input": 4, "output": 20, "cacheRead": 0.4, "cacheWrite5m": 5, "cacheWrite1h": 10, "longContext": { "above": 272000, "input": 8, "output": 30 } },
        "gpt-5.6-terra": { "input": 2, "output": 12, "cacheRead": 0.2, "cacheWrite5m": 2.5, "cacheWrite1h": 5, "longContext": { "above": 272000, "input": 4, "output": 18 } },
        "gpt-5.6-luna": { "input": 0.2, "output": 1.2, "cacheRead": 0.02, "cacheWrite5m": 0.25, "cacheWrite1h": 0.5, "longContext": { "above": 272000, "input": 0.4, "output": 1.8 } },
        "gpt-5.5": { "input": 5, "output": 30, "cacheRead": 0.5, "cacheWrite5m": 5, "cacheWrite1h": 5, "longContext": { "above": 272000, "input": 10, "output": 45 } },
        "gpt-5.4": { "input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite5m": 2.5, "cacheWrite1h": 2.5, "longContext": { "above": 272000, "input": 5, "output": 22.5 } },
        "gpt-5.4-mini": { "input": 0.75, "output": 4.5, "cacheRead": 0.075, "cacheWrite5m": 0.75, "cacheWrite1h": 0.75 },
        "gpt-5.3-codex": { "input": 1.75, "output": 14, "cacheRead": 0.175, "cacheWrite5m": 1.75, "cacheWrite1h": 1.75 },
        "gpt-5.2": { "input": 1.75, "output": 14, "cacheRead": 0.175, "cacheWrite5m": 1.75, "cacheWrite1h": 1.75 },
        "gpt-5.2-codex": { "input": 1.75, "output": 14, "cacheRead": 0.175, "cacheWrite5m": 1.75, "cacheWrite1h": 1.75 },
        "gpt-5.1": { "input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite5m": 1.25, "cacheWrite1h": 1.25 },
        "gpt-5.1-codex": { "input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite5m": 1.25, "cacheWrite1h": 1.25 },
        "gpt-5": { "input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite5m": 1.25, "cacheWrite1h": 1.25 },
        "gpt-5-codex": { "input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite5m": 1.25, "cacheWrite1h": 1.25 },
        "gpt-5-mini": { "input": 0.25, "output": 2, "cacheRead": 0.025, "cacheWrite5m": 0.25, "cacheWrite1h": 0.25 }
      }
    }
    """#

    static let document: PricingTable.Document = (try? PricingTable.Document.decode(Data(json.utf8)))
        ?? PricingTable.Document(models: [:])
}
