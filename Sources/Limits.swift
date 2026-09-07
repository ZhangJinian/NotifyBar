import Foundation

struct GetAccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    var windows: (fiveHour: RateLimitWindow?, weekly: RateLimitWindow?) {
        guard let snapshot = rateLimitsByLimitId?["codex"] ?? rateLimits else { return (nil, nil) }
        let candidates = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let five = candidates.first { $0.windowDurationMins == 300 }
        let week = candidates.first { $0.windowDurationMins == 10080 }
        // Legacy ordering is used only when BOTH durations are absent.
        if candidates.count == 2, candidates.allSatisfy({ $0.windowDurationMins == nil }) {
            return (snapshot.primary, snapshot.secondary)
        }
        return (five, week)
    }
}

struct RateLimitSnapshot: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    var remaining: String {
        guard let remainingPercent else { return "--" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    var reset: String {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        let seconds = resetsAt > 10_000_000_000 ? resetsAt / 1000 : resetsAt
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

func selfTest() throws {
    func parse(_ json: String) throws -> (fiveHour: RateLimitWindow?, weekly: RateLimitWindow?) {
        try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: Data(json.utf8)).windows
    }
    let weekOnly = try parse(#"{"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":10080}}}"#)
    precondition(weekOnly.fiveHour == nil && weekOnly.weekly?.remaining == "79%")
    let reversed = try parse(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":102,"windowDurationMins":10080},"secondary":{"usedPercent":-5,"windowDurationMins":300}}}}"#)
    precondition(reversed.fiveHour?.remaining == "100%" && reversed.weekly?.remaining == "0%")
    let missing = try parse(#"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#)
    precondition(missing.fiveHour?.remaining == "--" && missing.weekly == nil)
    let legacy = try parse(#"{"rateLimits":{"primary":{"usedPercent":10},"secondary":{"usedPercent":20}}}"#)
    precondition(legacy.fiveHour?.remaining == "90%" && legacy.weekly?.remaining == "80%")
    let unknown = try parse(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":60}}}"#)
    precondition(unknown.fiveHour == nil && unknown.weekly == nil)
    let seconds = RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: 1800000000)
    let millis = RateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: 1800000000000)
    precondition(seconds.reset == millis.reset)
    print("PASS: weekly-only, reversed windows, null quota, legacy windows, unknown duration, percent bounds, epoch units")
}
