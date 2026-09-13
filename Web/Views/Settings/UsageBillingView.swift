import SwiftUI
import UniformTypeIdentifiers

struct UsageBillingView: View {
    @ObservedObject private var usage = AIUsageStore.shared
    @ObservedObject private var budgets = UsageBudgetManager.shared
    @ObservedObject private var providers = AIProviderManager.shared
    @State private var range: RangeOption = .week
    @State private var exportDocument = UsageCSVDocument(text: "")
    @State private var exporting = false
    @State private var exportError: String?

    enum RangeOption: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days"
        var id: String { rawValue }
        func bounds(now: Date = Date()) -> ClosedRange<Date> {
            let calendar = Calendar.current
            let offset = self == .today ? 0 : self == .week ? -6 : -29
            let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
            return start...now
        }
    }

    private var events: [AIUsageEvent] { usage.events(in: range.bounds()) }

    var body: some View {
        SettingsStack {
            HStack {
                Picker("Period", selection: $range) {
                    ForEach(RangeOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 280)
                Spacer()
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    exportDocument = UsageCSVDocument(text: usage.exportCSV(in: range.bounds()))
                    exporting = true
                }
                .buttonStyle(.glass).disabled(events.isEmpty)
            }
            SettingsCard("Recorded usage", icon: "chart.bar") {
                if events.isEmpty {
                    Text("No requests in this period.").foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top) {
                        metric("Requests", value: events.count.formatted())
                        Spacer()
                        metric("Tokens", value: events.reduce(0) { $0 + $1.totalTokens }.formatted())
                        Spacer()
                        metric("Estimated cost", value: costDescription(events))
                    }
                    Divider()
                    ForEach(Array(usage.aggregate(in: range.bounds()).enumerated()), id: \.offset) { _, total in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(modelName(total.modelId)).fontWeight(.medium).lineLimit(1)
                                Text("\(providerName(total.providerId)) · \(total.totalTokens.formatted()) tokens")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(costDescription(events.filter {
                                    $0.providerId == total.providerId && $0.modelId == total.modelId
                                }))
                                Text("\(total.requestCount) requests").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Estimates may omit charges or interrupted replies. Your provider has the final bill.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard("Spending reminders", icon: "creditcard") {
                Text("Pause at a local estimate. Set a hard limit with your provider.")
                    .font(.caption).foregroundStyle(.secondary)
                let external = providers.availableProviders.filter { $0.providerType == .external }
                if external.isEmpty {
                    Button("Connect a provider") { SettingsView.open(.aiProvider) }.buttonStyle(.glass)
                }
                ForEach(external, id: \.providerId) { provider in
                    Divider()
                    UsageBudgetRow(providerID: provider.providerId, name: provider.displayName,
                        initial: budgets.getBudget(for: provider.providerId)
                            ?? .init(dailyUSD: nil, monthlyUSD: nil, blockOnExceed: false))
                }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.secondary) }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .commaSeparatedText, defaultFilename: "Web AI usage") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit()
        }
    }

    private func costDescription(_ events: [AIUsageEvent]) -> String {
        guard events.allSatisfy({ $0.estimatedCostUSD != nil }) else { return "Incomplete" }
        let cost = events.compactMap(\.estimatedCostUSD).reduce(0, +)
        return cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
    }

    private func providerName(_ id: String) -> String {
        providers.availableProviders.first(where: { $0.providerId == id })?.displayName ?? id
    }

    private func modelName(_ id: String) -> String {
        providers.availableProviders.flatMap(\.availableModels).first(where: { $0.id == id })?.name ?? id
    }
}

private struct UsageBudgetRow: View {
    let providerID: String
    let name: String
    @State private var daily: String
    @State private var monthly: String
    @State private var pause: Bool
    @State private var saved = false

    init(providerID: String, name: String, initial: UsageBudgetManager.Budget) {
        self.providerID = providerID
        self.name = name
        _daily = State(initialValue: initial.dailyUSD.map { String($0) } ?? "")
        _monthly = State(initialValue: initial.monthlyUSD.map { String($0) } ?? "")
        _pause = State(initialValue: initial.blockOnExceed)
    }

    private var valid: Bool { [daily, monthly].allSatisfy { value in
        value.isEmpty || (Double(value).map { $0.isFinite && $0 >= 0 } ?? false)
    } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).fontWeight(.medium)
            HStack(spacing: 12) {
                budgetField("Daily, USD", value: $daily)
                budgetField("Monthly, USD", value: $monthly)
            }
            HStack {
                Toggle("Pause at estimate", isOn: $pause).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button(saved ? "Saved" : "Save") {
                    UsageBudgetManager.shared.setBudget(for: providerID,
                        budget: .init(dailyUSD: Double(daily), monthlyUSD: Double(monthly), blockOnExceed: pause))
                    saved = true
                }
                .buttonStyle(.glass).disabled(!valid || saved)
            }
            if !valid { Text("Enter a positive amount, or leave blank for no limit.").font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: daily) { _, _ in saved = false }
        .onChange(of: monthly) { _, _ in saved = false }
        .onChange(of: pause) { _, _ in saved = false }
    }

    private func budgetField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("No limit", text: value).textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(name) \(title)")
        }
    }
}

private struct UsageCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
