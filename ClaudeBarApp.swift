import SwiftUI
import AppKit
import Foundation

// MARK: - Data Models

struct DailyActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
}

struct LongestSession: Codable {
    let duration: Int
    let messageCount: Int
    let timestamp: String
}

struct StatsCache: Codable {
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ModelUsage]
    let totalSessions: Int
    let totalMessages: Int
    let longestSession: LongestSession
    let firstSessionDate: String
    let hourCounts: [String: Int]
}

struct SettingsFile: Codable {
    let enabledPlugins: [String: Bool]?
    let effortLevel: String?
}

struct RateLimitWindow {
    let usedPercentage: Double
    let resetsAt: String
}

struct UsageData {
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?
    var model: String?
    var lastUpdated: Date?
    var sessionCost: Double = 0
    var contextUsedPct: Double = 0
    var contextWindowSize: Int = 0
}

struct ModelInfo: Identifiable {
    let id: String
    let shortName: String
    let color: NSColor
    let outputTokens: Int
    let inputTokens: Int
    let cacheRead: Int
}

// MARK: - Constants

let kModelColors: [String: NSColor] = [
    "claude-opus-4-6": .systemPurple,
    "claude-opus-4-5-20251101": .systemIndigo,
    "claude-sonnet-4-6": .systemOrange,
    "claude-sonnet-4-5-20250929": .systemGreen,
    "claude-haiku-4-5-20251001": .systemTeal
]
let kModelNames: [String: String] = [
    "claude-opus-4-6": "Opus 4.6",
    "claude-opus-4-5-20251101": "Opus 4.5",
    "claude-sonnet-4-6": "Sonnet 4.6",
    "claude-sonnet-4-5-20250929": "Sonnet 4.5",
    "claude-haiku-4-5-20251001": "Haiku 4.5"
]

// MARK: - Data Loading

func loadStatsCache() -> StatsCache? {
    let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stats-cache.json")
    guard let d = try? Data(contentsOf: p) else { return nil }
    return try? JSONDecoder().decode(StatsCache.self, from: d)
}

func loadSettings() -> SettingsFile? {
    let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    guard let d = try? Data(contentsOf: p) else { return nil }
    return try? JSONDecoder().decode(SettingsFile.self, from: d)
}

func loadUsageData() -> UsageData {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/claudebar-usage.json")
    guard let data = try? Data(contentsOf: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return UsageData() }

    var u = UsageData()
    if let m = json["model"] as? [String: Any] { u.model = m["display_name"] as? String ?? m["id"] as? String }
    else { u.model = json["model"] as? String }
    u.lastUpdated = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    if let c = json["cost"] as? [String: Any] { u.sessionCost = c["total_cost_usd"] as? Double ?? 0 }
    if let cw = json["context_window"] as? [String: Any] {
        u.contextUsedPct = (cw["used_percentage"] as? Double) ?? Double(cw["used_percentage"] as? Int ?? 0)
        u.contextWindowSize = cw["context_window_size"] as? Int ?? 0
    }
    if let rl = json["rate_limits"] as? [String: Any] {
        for (key, windowKey) in [("five_hour", \UsageData.fiveHour), ("seven_day", \UsageData.sevenDay)] {
            if let w = rl[key] as? [String: Any] {
                let pct = (w["used_percentage"] as? Double) ?? Double(w["used_percentage"] as? Int ?? 0)
                let reset: String
                if let ts = w["resets_at"] as? Int { reset = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
                else { reset = w["resets_at"] as? String ?? "" }
                u[keyPath: windowKey] = RateLimitWindow(usedPercentage: pct, resetsAt: reset)
            }
        }
    }
    return u
}

func getClaudeVersion() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let searchPaths = [
        "\(home)/.local/bin/claude",
        "\(home)/.claude/local/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude"
    ]
    let claudePath = searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }

    let pipe = Pipe(); let proc = Process()
    if let path = claudePath {
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
    } else {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "--version"]
    }
    proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return "Unknown" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); proc.waitUntilExit()
    guard proc.terminationStatus == 0, let s = String(data: d, encoding: .utf8) else { return "Unknown" }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func countProjects() -> Int {
    let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    return (try? FileManager.default.contentsOfDirectory(atPath: p.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
}

// MARK: - Monitor

class ClaudeMonitor: ObservableObject {
    @Published var stats: StatsCache?
    @Published var settings: SettingsFile?
    @Published var usage = UsageData()
    @Published var claudeVersion = "..."
    @Published var projectCount = 0
    @Published var models: [ModelInfo] = []
    @Published var todayActivity: DailyActivity?
    @Published var peakHour = 0
    @Published var activeDays = 0
    @Published var totalOutputTokens = 0
    @Published var enabledPluginCount = 0
    @Published var mostActiveDay = ""
    @Published var currentStreak = 0
    @Published var longestStreak = 0
    @Published var favoriteModel = ""
    @Published var totalTokensAll = 0
    @Published var heatmapData: [Int: Int] = [:]

    private var statsTimer: Timer?
    private var usageTimer: Timer?

    init() {
        refreshAll()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in self?.refreshStats() }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshUsage() }
    }
    deinit { statsTimer?.invalidate(); usageTimer?.invalidate() }

    func refreshAll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = loadStatsCache(); let st = loadSettings(); let u = loadUsageData()
            let v = getClaudeVersion(); let p = countProjects()
            DispatchQueue.main.async { guard let self = self else { return }
                self.stats = s; self.settings = st; self.usage = u; self.claudeVersion = v; self.projectCount = p; self.processStats()
            }
        }
    }

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = loadStatsCache()
            DispatchQueue.main.async { guard let self = self else { return }; self.stats = s; self.processStats() }
        }
    }

    func refreshUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let u = loadUsageData()
            DispatchQueue.main.async { self?.usage = u }
        }
    }

    private func processStats() {
        guard let stats = stats else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current

        let totalOut = stats.modelUsage.values.reduce(0) { $0 + $1.outputTokens }
        totalOutputTokens = totalOut
        totalTokensAll = stats.modelUsage.values.reduce(0) { $0 + $1.outputTokens + $1.inputTokens }

        models = stats.modelUsage.map { (k, u) in
            ModelInfo(id: k, shortName: kModelNames[k] ?? k, color: kModelColors[k] ?? .systemGray,
                      outputTokens: u.outputTokens, inputTokens: u.inputTokens, cacheRead: u.cacheReadInputTokens)
        }.sorted { $0.outputTokens > $1.outputTokens }

        favoriteModel = models.first?.shortName ?? ""
        todayActivity = stats.dailyActivity.first { $0.date == df.string(from: Date()) }
        peakHour = Int(stats.hourCounts.max(by: { $0.value < $1.value })?.key ?? "0") ?? 0
        activeDays = stats.dailyActivity.count

        if let max = stats.dailyActivity.max(by: { $0.messageCount < $1.messageCount }) {
            mostActiveDay = shortDate(max.date)
        }

        // Streaks
        let sorted = stats.dailyActivity.map { $0.date }.sorted()
        let todayStr = df.string(from: Date())
        var streak = 0; var check = Date()
        if !sorted.contains(todayStr) { check = cal.date(byAdding: .day, value: -1, to: check)! }
        let allDates = Set(sorted)
        while allDates.contains(df.string(from: check)) { streak += 1; check = cal.date(byAdding: .day, value: -1, to: check)! }
        currentStreak = streak
        var maxS = 0; var curS = 1
        for i in 1..<sorted.count {
            if let d1 = df.date(from: sorted[i-1]), let d2 = df.date(from: sorted[i]),
               cal.dateComponents([.day], from: d1, to: d2).day == 1 { curS += 1 }
            else { maxS = max(maxS, curS); curS = 1 }
        }
        longestStreak = max(maxS, curS)

        // Heatmap
        var hm: [Int: Int] = [:]
        let todayStart = cal.startOfDay(for: Date())
        for a in stats.dailyActivity {
            if let d = df.date(from: a.date) {
                hm[cal.dateComponents([.day], from: todayStart, to: cal.startOfDay(for: d)).day ?? 0] = a.messageCount
            }
        }
        heatmapData = hm
        enabledPluginCount = settings?.enabledPlugins?.filter { $0.value }.count ?? 0
    }
}

// MARK: - Formatting

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
    return "\(n)"
}

func formatNumber(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func formatHour(_ h: Int) -> String { h == 0 ? "12AM" : h < 12 ? "\(h)AM" : h == 12 ? "12PM" : "\(h-12)PM" }

func shortDate(_ s: String) -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    guard let d = df.date(from: s) else { return s }
    let o = DateFormatter(); o.dateFormat = "MMM d"; return o.string(from: d)
}

func formatDuration(_ ms: Int) -> String {
    let s = ms / 1000; let d = s / 86400; let h = (s % 86400) / 3600; let m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }; if h > 0 { return "\(h)h \(m)m" }; return "\(m)m"
}

func isStale(_ dateStr: String) -> Bool {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    guard df.date(from: dateStr) != nil else { return true }
    let today = df.string(from: Date())
    return dateStr != today
}

func resetTimeLocal(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return "" }
    let df = DateFormatter(); df.dateFormat = "h:mma"; df.timeZone = .current
    return "Resets \(df.string(from: date).lowercased()) (\(TimeZone.current.abbreviation() ?? ""))"
}

// MARK: - Theme

struct Theme {
    static let pad: CGFloat = 16
    static let cardBg = Color.primary.opacity(0.04)
    static let cardRadius: CGFloat = 10
    static let accent = Color(NSColor.systemPurple)
    static let warm = Color.orange
}

// MARK: - Card Wrapper

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBg)
            .cornerRadius(Theme.cardRadius)
    }
}

// MARK: - Usage Bar

struct UsageBar: View {
    let title: String
    let percentage: Double
    let resetInfo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(percentage))% used")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor.opacity(0.8))
                        .frame(width: max(0, geo.size.width * CGFloat(min(percentage / 100, 1.0))))
                }
            }
            .frame(height: 10)
            Text(resetInfo)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    var barColor: Color {
        if percentage >= 80 { return .red }
        if percentage >= 50 { return .orange }
        return Color(NSColor.systemIndigo)
    }
}

// MARK: - Stat Pair

struct StatPair: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color.opacity(0.7))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Heatmap

struct HeatmapView: View {
    let data: [Int: Int]
    let maxCount: Int
    private let dayLabelWidth: CGFloat = 20
    private let totalWeeks = 26

    var body: some View {
        let cal = Calendar.current
        let today = Date()
        let todayWeekday = cal.component(.weekday, from: today) - 1

        GeometryReader { geo in
            let gridWidth = geo.size.width - dayLabelWidth - 4
            let sp: CGFloat = 2
            let cs = (gridWidth - CGFloat(totalWeeks - 1) * sp) / CGFloat(totalWeeks)

            VStack(alignment: .leading, spacing: 3) {
                // Months
                HStack(spacing: 0) {
                    Spacer().frame(width: dayLabelWidth + 4)
                    ForEach(monthLabels(totalWeeks: totalWeeks, wd: todayWeekday, today: today), id: \.0) { (_, label, span) in
                        Text(label).font(.system(size: 8)).foregroundColor(.secondary)
                            .frame(width: CGFloat(span) * (cs + sp), alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: sp) {
                        ForEach(0..<7, id: \.self) { r in
                            Text(r == 1 ? "M" : r == 3 ? "W" : r == 5 ? "F" : "")
                                .font(.system(size: 7)).foregroundColor(.secondary)
                                .frame(width: dayLabelWidth, height: cs, alignment: .trailing)
                        }
                    }.padding(.trailing, 4)
                    HStack(spacing: sp) {
                        ForEach(0..<totalWeeks, id: \.self) { week in
                            VStack(spacing: sp) {
                                ForEach(0..<7, id: \.self) { dow in
                                    let offset = -((totalWeeks - 1 - week) * 7 + (todayWeekday - dow))
                                    let count = data[offset] ?? 0
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(offset > 0 ? Color.clear : heatColor(count))
                                        .frame(width: cs, height: cs)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 3) {
                    Spacer()
                    Text("Less").font(.system(size: 7)).foregroundColor(.secondary)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i == 0 ? Color.primary.opacity(0.06) : Theme.warm.opacity(0.15 + i * 0.65))
                            .frame(width: 9, height: 9)
                    }
                    Text("More").font(.system(size: 7)).foregroundColor(.secondary)
                }
            }
        }.frame(height: 135)
    }

    private func heatColor(_ c: Int) -> Color {
        c == 0 ? Color.primary.opacity(0.06) : Theme.warm.opacity(0.15 + min(Double(c) / max(Double(maxCount), 1), 1) * 0.65)
    }

    private func monthLabels(totalWeeks: Int, wd: Int, today: Date) -> [(Int, String, Int)] {
        let cal = Calendar.current; let df = DateFormatter(); df.dateFormat = "MMM"
        var labels: [(Int, String, Int)] = []; var lastMonth = -1; var lastIdx = 0
        for w in 0..<totalWeeks {
            let date = cal.date(byAdding: .day, value: -((totalWeeks - 1 - w) * 7 + wd), to: today)!
            let m = cal.component(.month, from: date)
            if m != lastMonth {
                if !labels.isEmpty { labels[labels.count - 1].2 = w - lastIdx }
                labels.append((w, df.string(from: date), 0)); lastMonth = m; lastIdx = w
            }
        }
        if !labels.isEmpty { labels[labels.count - 1].2 = totalWeeks - lastIdx }
        return labels
    }
}

// MARK: - Hourly Chart

struct HourlyChart: View {
    let hourCounts: [String: Int]
    var body: some View {
        let maxC = max(hourCounts.values.max() ?? 1, 1)
        GeometryReader { geo in
            let bw = geo.size.width / 24
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { h in
                    let c = hourCounts["\(h)"] ?? 0; let f = CGFloat(c) / CGFloat(maxC)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(c == maxC ? Theme.accent : (c > 0 ? Theme.accent.opacity(0.4) : Color.clear))
                            .frame(width: max(bw - 2, 2), height: max(f * geo.size.height * 0.9, c > 0 ? 2 : 0))
                    }.frame(width: bw, height: geo.size.height)
                }
            }
        }
    }
}

// MARK: - Tokens Chart

struct TokensChart: View {
    let data: [DailyModelTokens]
    var body: some View {
        let maxT = data.map { $0.tokensByModel.values.reduce(0, +) }.max() ?? 1
        GeometryReader { geo in
            let bw = max((geo.size.width - CGFloat(data.count)) / CGFloat(max(data.count, 1)), 2)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, e in
                    let total = e.tokensByModel.values.reduce(0, +)
                    let frac = CGFloat(total) / CGFloat(maxT)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            ForEach(e.tokensByModel.sorted(by: { $0.value > $1.value }), id: \.key) { k, v in
                                Rectangle().fill(Color(kModelColors[k] ?? .systemGray))
                                    .frame(height: max(CGFloat(v) / CGFloat(max(total, 1)) * frac * geo.size.height * 0.9, 0))
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 2))
                    }.frame(width: bw)
                }
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var monitor = ClaudeMonitor()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.5).padding(.horizontal, Theme.pad)

            Group {
                if tab == 0 { usageTab }
                else if tab == 1 { statsTab }
                else { modelsTab }
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: 420, height: 540)
        .background(.background)
    }

    // MARK: Header
    var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("ClaudeBar")
                    .font(.system(size: 15, weight: .bold))
            }
            Spacer()
            Text("v\(monitor.claudeVersion.replacingOccurrences(of: " (Claude Code)", with: ""))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(4)
        }
        .padding(.horizontal, Theme.pad).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: Tab Bar
    var tabBar: some View {
        HStack(spacing: 2) {
            TabPill(title: "Usage", icon: "gauge.with.needle", sel: tab == 0) { tab = 0 }
            TabPill(title: "Stats", icon: "chart.bar", sel: tab == 1) { tab = 1 }
            TabPill(title: "Models", icon: "cpu", sel: tab == 2) { tab = 2 }
            Spacer()
        }
        .padding(.horizontal, Theme.pad).padding(.bottom, 8)
    }

    // MARK: Footer
    var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5).padding(.horizontal, Theme.pad)
            HStack(spacing: 8) {
                if let lu = monitor.usage.lastUpdated {
                    let df = RelativeDateTimeFormatter()
                    Text(df.localizedString(for: lu, relativeTo: Date()))
                        .font(.system(size: 8)).foregroundColor(.secondary.opacity(0.5))
                }
                Spacer()
                Button(action: { monitor.refreshAll() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, Theme.pad).padding(.vertical, 7)
        }
    }

    // MARK: Usage Tab
    var usageTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                let hasUsage = monitor.usage.fiveHour != nil

                if hasUsage {
                    // Active model badge
                    if let model = monitor.usage.model {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundColor(.green)
                            Text(model)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            if monitor.usage.sessionCost > 0 {
                                Text(String(format: "$%.2f", monitor.usage.sessionCost))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.green.opacity(0.06))
                        .cornerRadius(8)
                    }

                    // Rate limits
                    Card {
                        VStack(spacing: 14) {
                            if let fh = monitor.usage.fiveHour {
                                UsageBar(title: "Current session", percentage: fh.usedPercentage, resetInfo: resetTimeLocal(fh.resetsAt))
                            }
                            if let sd = monitor.usage.sevenDay {
                                UsageBar(title: "Current week (all models)", percentage: sd.usedPercentage, resetInfo: resetTimeLocal(sd.resetsAt))
                            }
                        }
                    }

                    // Context window
                    if monitor.usage.contextUsedPct > 0 {
                        Card {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Context window")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("\(Int(monitor.usage.contextUsedPct))%")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.blue)
                                    if monitor.usage.contextWindowSize > 0 {
                                        Text("of \(formatTokens(monitor.usage.contextWindowSize))")
                                            .font(.system(size: 9)).foregroundColor(.secondary)
                                    }
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                                        RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.5))
                                            .frame(width: geo.size.width * CGFloat(monitor.usage.contextUsedPct / 100))
                                    }
                                }.frame(height: 6)
                            }
                        }
                    }
                } else {
                    Card {
                        VStack(spacing: 10) {
                            Image(systemName: "gauge.with.needle")
                                .font(.system(size: 28))
                                .foregroundStyle(
                                    LinearGradient(colors: [.purple.opacity(0.4), .blue.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                                )
                            Text("Waiting for usage data")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("Usage appears automatically when you\nuse Claude Code in a terminal session.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }

                // Today
                if let today = monitor.todayActivity {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Today").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            HStack(spacing: 0) {
                                StatPair(icon: "bubble.left.fill", label: "Messages", value: "\(today.messageCount)", color: .blue)
                                StatPair(icon: "terminal", label: "Sessions", value: "\(today.sessionCount)", color: Theme.accent)
                                StatPair(icon: "wrench.fill", label: "Tools", value: "\(today.toolCallCount)", color: .green)
                            }
                        }
                    }
                }

                // Summary
                Card {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            StatPair(icon: "number", label: "Sessions", value: formatNumber(monitor.stats?.totalSessions ?? 0), color: Theme.warm)
                            StatPair(icon: "text.bubble", label: "Messages", value: formatNumber(monitor.stats?.totalMessages ?? 0), color: Theme.warm)
                        }
                        HStack(spacing: 0) {
                            StatPair(icon: "star.fill", label: "Favorite", value: monitor.favoriteModel, color: Theme.accent)
                            StatPair(icon: "bolt.fill", label: "Tokens out", value: formatTokens(monitor.totalOutputTokens), color: Theme.warm)
                        }
                    }
                }
            }
            .padding(Theme.pad)
        }
    }

    // MARK: Stats Tab
    var statsTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Stale data hint
                if let lcd = monitor.stats?.lastComputedDate, isStale(lcd) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                        Text("Data through \(shortDate(lcd))")
                            .font(.system(size: 10))
                        Spacer()
                        Text("Run /stats in Claude Code to refresh")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.yellow.opacity(0.06))
                    .cornerRadius(6)
                }

                HeatmapView(data: monitor.heatmapData, maxCount: monitor.heatmapData.values.max() ?? 1)

                Card {
                    VStack(spacing: 8) {
                        HStack(spacing: 0) {
                            StatPair(icon: "calendar", label: "Active days", value: "\(monitor.activeDays)", color: Theme.warm)
                            StatPair(icon: "flame.fill", label: "Current streak", value: "\(monitor.currentStreak)d", color: Theme.warm)
                        }
                        HStack(spacing: 0) {
                            StatPair(icon: "trophy.fill", label: "Most active", value: monitor.mostActiveDay, color: Theme.warm)
                            StatPair(icon: "flag.fill", label: "Best streak", value: "\(monitor.longestStreak)d", color: Theme.warm)
                        }
                        HStack(spacing: 0) {
                            StatPair(icon: "timer", label: "Longest session", value: formatDuration(monitor.stats?.longestSession.duration ?? 0), color: Theme.warm)
                            StatPair(icon: "folder.fill", label: "Projects", value: "\(monitor.projectCount)", color: Theme.warm)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hourly activity").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            Spacer()
                            Text("Peak \(formatHour(monitor.peakHour))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.accent)
                        }
                        HourlyChart(hourCounts: monitor.stats?.hourCounts ?? [:]).frame(height: 30)
                        HStack {
                            Text("12AM").font(.system(size: 7)).foregroundColor(.secondary)
                            Spacer()
                            Text("6AM").font(.system(size: 7)).foregroundColor(.secondary)
                            Spacer()
                            Text("12PM").font(.system(size: 7)).foregroundColor(.secondary)
                            Spacer()
                            Text("6PM").font(.system(size: 7)).foregroundColor(.secondary)
                            Spacer()
                            Text("12AM").font(.system(size: 7)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(Theme.pad)
        }
    }

    // MARK: Models Tab
    var modelsTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if let tpd = monitor.stats?.dailyModelTokens, !tpd.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tokens per Day").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            let maxT = tpd.map { $0.tokensByModel.values.reduce(0, +) }.max() ?? 1
                            HStack(alignment: .top, spacing: 4) {
                                VStack(alignment: .trailing) {
                                    Text(formatTokens(maxT)).font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary)
                                    Spacer()
                                    Text("0").font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary)
                                }.frame(width: 28, height: 70)
                                TokensChart(data: tpd).frame(height: 70)
                            }
                            HStack {
                                Text("    ")
                                Text(shortDate(tpd.first?.date ?? "")).font(.system(size: 7)).foregroundColor(.secondary)
                                Spacer()
                                Text(shortDate(tpd.last?.date ?? "")).font(.system(size: 7)).foregroundColor(.secondary)
                            }
                            HStack(spacing: 12) {
                                ForEach(monitor.models.prefix(4)) { m in
                                    HStack(spacing: 3) {
                                        Circle().fill(Color(m.color)).frame(width: 6, height: 6)
                                        Text(m.shortName).font(.system(size: 9, weight: .medium))
                                    }
                                }
                            }.padding(.top, 2)
                        }
                    }
                }

                ForEach(monitor.models) { m in
                    let maxOut = monitor.models.first?.outputTokens ?? 1
                    let pct = Double(m.outputTokens) / max(Double(monitor.totalOutputTokens), 1) * 100

                    Card {
                        VStack(spacing: 5) {
                            HStack {
                                Circle().fill(Color(m.color)).frame(width: 8, height: 8)
                                Text(m.shortName).font(.system(size: 12, weight: .semibold))
                                Text(String(format: "%.1f%%", pct))
                                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                Spacer()
                                Text(formatTokens(m.outputTokens))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(m.color))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color(m.color).opacity(0.1))
                                    RoundedRectangle(cornerRadius: 3).fill(Color(m.color).opacity(0.55))
                                        .frame(width: max(0, geo.size.width * CGFloat(Double(m.outputTokens) / max(Double(maxOut), 1))))
                                }
                            }.frame(height: 5)
                            HStack(spacing: 16) {
                                Text("In: \(formatTokens(m.inputTokens))").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                Text("Out: \(formatTokens(m.outputTokens))").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                Text("Cache: \(formatTokens(m.cacheRead))").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(Theme.pad)
        }
    }
}

// MARK: - Tab Pill

struct TabPill: View {
    let title: String; let icon: String; let sel: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 11, weight: sel ? .semibold : .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(sel ? Theme.accent.opacity(0.12) : Color.clear)
            .foregroundColor(sel ? Theme.accent : .secondary)
            .cornerRadius(6)
        }.buttonStyle(.plain)
    }
}

// MARK: - Auto Setup

func ensureStatuslineConfigured() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let claudeDir = home.appendingPathComponent(".claude")
    let scriptPath = claudeDir.appendingPathComponent("claudebar-statusline.sh")
    let settingsPath = claudeDir.appendingPathComponent("settings.json")

    guard FileManager.default.fileExists(atPath: claudeDir.path) else { return }

    // 1. Create statusline script if missing
    if !FileManager.default.fileExists(atPath: scriptPath.path) {
        let script = """
        #!/bin/bash
        INPUT=$(cat)
        echo "$INPUT" > "$HOME/.claude/claudebar-usage.json"
        echo "$INPUT" | python3 -c "
        import sys, json
        try:
            d = json.load(sys.stdin)
            r = d.get('rate_limits', {})
            h = r.get('five_hour', {})
            w = r.get('seven_day', {})
            print(f'Session: {h.get(\\\"used_percentage\\\", \\\"?\\\"):}% | Week: {w.get(\\\"used_percentage\\\", \\\"?\\\"):}%')
        except: pass
        " 2>/dev/null
        """
        try? script.write(to: scriptPath, atomically: true, encoding: .utf8)
        // chmod +x
        var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptPath.path)) ?? [:]
        attrs[.posixPermissions] = 0o755
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptPath.path)
    }

    // 2. Add statusLine to settings.json if not already present
    if FileManager.default.fileExists(atPath: settingsPath.path) {
        guard let data = try? Data(contentsOf: settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Check if statusLine already references claudebar
        if let sl = json["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String, cmd.contains("claudebar") { return }
        json["statusLine"] = ["type": "command", "command": "bash \(scriptPath.path)"] as [String: Any]
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsPath)
        }
    } else {
        // Create minimal settings.json
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "bash \(scriptPath.path)"]]
        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? out.write(to: settingsPath)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-configure statusline on first launch
        ensureStatuslineConfigured()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "ClaudeBar")
            button.action = #selector(togglePopover)
            button.target = self
        }
        let p = NSPopover()
        p.contentSize = NSSize(width: 420, height: 540)
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = p
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
