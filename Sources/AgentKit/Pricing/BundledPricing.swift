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
        "claude-haiku-4-5": { "input": 1, "output": 5 }
      }
    }
    """#

    static let document: PricingTable.Document = (try? PricingTable.Document.decode(Data(json.utf8)))
        ?? PricingTable.Document(models: [:])
}
