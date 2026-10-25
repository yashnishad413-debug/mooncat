import Foundation

enum ReminderParser {
    static func parse(_ text: String, now: Date = Date()) -> (title: String, fireDate: Date)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        
        let cal = Calendar(identifier: .gregorian)
        
        // 1. "in ..." patterns (relative to now)
        if let (mins, rest) = parseInDuration(s) {
            guard let fireDate = cal.date(byAdding: .minute, value: mins, to: now) else { return nil }
            return (title: rest.trimmingCharacters(in: .whitespaces), fireDate: fireDate)
        }
        
        // 2. "tomorrow" time
        if let (hour, minute, rest) = parseTomorrowTime(s) {
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  let fireDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) else { return nil }
            return (title: rest.trimmingCharacters(in: .whitespaces), fireDate: fireDate)
        }
        
        // 3. Time of day with am/pm (checked before 24h to avoid ambiguity)
        if let (hour, minute, rest) = parseTimeAmPm(s) {
            guard var fireDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            if fireDate <= now {
                guard let next = cal.date(byAdding: .day, value: 1, to: fireDate) else { return nil }
                fireDate = next
            }
            return (title: rest.trimmingCharacters(in: .whitespaces), fireDate: fireDate)
        }
        
        // 4. 24-hour HH:MM
        if let (hour, minute, rest) = parseTime24h(s) {
            guard var fireDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            if fireDate <= now {
                guard let next = cal.date(byAdding: .day, value: 1, to: fireDate) else { return nil }
                fireDate = next
            }
            return (title: rest.trimmingCharacters(in: .whitespaces), fireDate: fireDate)
        }
        
        // 5. Plain duration at start
        if let (mins, rest) = parsePlainDuration(s) {
            guard let fireDate = cal.date(byAdding: .minute, value: mins, to: now) else { return nil }
            return (title: rest.trimmingCharacters(in: .whitespaces), fireDate: fireDate)
        }
        
        return nil
    }
    
    // MARK: - Duration parsing
    
    private static func parseInDuration(_ s: String) -> (Int, String)? {
        guard s.lowercased().hasPrefix("in ") else { return nil }
        return parseDurationString(String(s.dropFirst(3)))
    }
    
    private static func parsePlainDuration(_ s: String) -> (Int, String)? {
        return parseDurationString(s)
    }
    
    private static func parseDurationString(_ s: String) -> (Int, String)? {
        // Compound: X hours Y minutes
        if let m = firstMatch(pattern: "^(\\d+)\\s*(?:hours?|hrs?|h)\\s+(\\d+)\\s*(?:minutes?|mins?|m)(.*)$", in: s) {
            guard let h = Int(m[1]), let mm = Int(m[2]) else { return nil }
            return (h * 60 + mm, m[3])
        }
        // Shorthand: XhYm
        if let m = firstMatch(pattern: "^(\\d+)h(\\d+)m(.*)$", in: s) {
            guard let h = Int(m[1]), let mm = Int(m[2]) else { return nil }
            return (h * 60 + mm, m[3])
        }
        // Single unit
        if let m = firstMatch(pattern: "^(\\d+)\\s*(hours?|hrs?|h|minutes?|mins?|m)\\b(.*)$", in: s) {
            guard let num = Int(m[1]) else { return nil }
            let unit = m[2].lowercased()
            let mins = unit.hasPrefix("h") ? num * 60 : num
            return (mins, m[3])
        }
        return nil
    }
    
    // MARK: - Time of day parsing
    
    private static func parseTomorrowTime(_ s: String) -> (Int, Int, String)? {
        guard s.lowercased().hasPrefix("tomorrow ") else { return nil }
        return parseTimeComponent(String(s.dropFirst(9)))
    }
    
    private static func parseTimeComponent(_ s: String) -> (Int, Int, String)? {
        if let r = parseTimeAmPm(s) { return r }
        if let r = parseTime24h(s) { return r }
        return nil
    }
    
    private static func parseTimeAmPm(_ s: String) -> (Int, Int, String)? {
        // H:MM am/pm
        if let m = firstMatch(pattern: "^(?i)(\\d{1,2}):(\\d{2})\\s*(am|pm)(.*)$", in: s) {
            guard var hour = Int(m[1]), let minute = Int(m[2]),
                  hour >= 1 && hour <= 12, minute >= 0 && minute < 60 else { return nil }
            let ampm = m[3].lowercased()
            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }
            return (hour, minute, m[4])
        }
        // H am/pm
        if let m = firstMatch(pattern: "^(?i)(\\d{1,2})\\s*(am|pm)\\b(.*)$", in: s) {
            guard var hour = Int(m[1]), hour >= 1 && hour <= 12 else { return nil }
            let ampm = m[2].lowercased()
            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }
            return (hour, 0, m[3])
        }
        return nil
    }
    
    private static func parseTime24h(_ s: String) -> (Int, Int, String)? {
        if let m = firstMatch(pattern: "^(\\d{1,2}):(\\d{2})\\b(.*)$", in: s) {
            guard let hour = Int(m[1]), let minute = Int(m[2]),
                  hour >= 0 && hour < 24, minute >= 0 && minute < 60 else { return nil }
            return (hour, minute, m[3])
        }
        return nil
    }
    
    // MARK: - Regex helper
    
    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location == NSNotFound {
                groups.append("")
            } else if let rng = Range(r, in: text) {
                groups.append(String(text[rng]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
    
    // MARK: - Self-tests
    
    static func runSelfTests() -> [String] {
        var failures: [String] = []
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 15
        comps.hour = 14; comps.minute = 0; comps.second = 0
        guard let now = cal.date(from: comps) else {
            return ["Could not create test date"]
        }
        
        func check(_ input: String, expectedMins: Int?, expectedTitle: String?) {
            let result = parse(input, now: now)
            if expectedMins == nil && expectedTitle == nil {
                if result != nil {
                    failures.append("Expected nil for '\(input)', got \(result!)")
                }
                return
            }
            guard let r = result else {
                failures.append("Expected result for '\(input)', got nil")
                return
            }
            guard let expectedDate = cal.date(byAdding: .minute, value: expectedMins!, to: now) else {
                failures.append("'\(input)': could not compute expected date")
                return
            }
            let diff = abs(r.fireDate.timeIntervalSince(expectedDate))
            if diff > 1 {
                failures.append("'\(input)': expected date \(expectedDate), got \(r.fireDate)")
            }
            if r.title != expectedTitle {
                failures.append("'\(input)': expected title '\(expectedTitle ?? "")', got '\(r.title)'")
            }
        }
        
        check("20m stretch",            expectedMins: 20,   expectedTitle: "stretch")
        check("1h30m tea",              expectedMins: 90,   expectedTitle: "tea")
        check("in 2 hours laundry",     expectedMins: 120,  expectedTitle: "laundry")
        check("in 90 min call",         expectedMins: 90,   expectedTitle: "call")
        check("3pm call mom",           expectedMins: 60,   expectedTitle: "call mom")
        check("10am x",                 expectedMins: 1200, expectedTitle: "x")
        check("3:30pm x",               expectedMins: 90,   expectedTitle: "x")
        check("15:30 x",                expectedMins: 90,   expectedTitle: "x")
        check("tomorrow 9am y",         expectedMins: 1140, expectedTitle: "y")
        check("stretch",                expectedMins: nil,  expectedTitle: nil)
        check("5m",                     expectedMins: 5,    expectedTitle: "")
        check("1h work",                expectedMins: 60,   expectedTitle: "work")
        check("in 1 hour work",         expectedMins: 60,   expectedTitle: "work")
        check("10:00 meeting",          expectedMins: 1200, expectedTitle: "meeting")
        check("9am coffee",             expectedMins: 1140, expectedTitle: "coffee")
        check("tomorrow 5pm dentist",   expectedMins: 1620, expectedTitle: "dentist")
        check("2h30m movie",            expectedMins: 150,  expectedTitle: "movie")
        
        return failures
    }
}