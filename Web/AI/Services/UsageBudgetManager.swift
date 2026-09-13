import Foundation

/// Simple budget manager for AI usage costs per provider
@MainActor
final class UsageBudgetManager: ObservableObject {
    static let shared = UsageBudgetManager()

    struct Budget: Codable, Equatable {
        var dailyUSD: Double?
        var monthlyUSD: Double?
        var blockOnExceed: Bool
    }

    @Published private(set) var providerBudgets: [String: Budget] = [:]
    @Published private(set) var lastAlert: (providerId: String, message: String)?

    private let userDefaults = UserDefaults.standard
    private let budgetsKey = "ai_usage_budgets"

    private init() {
        load()
    }

    func setBudget(for providerId: String, budget: Budget) {
        providerBudgets[providerId] = budget
        persist()
    }

    func getBudget(for providerId: String) -> Budget? {
        providerBudgets[providerId]
    }

    /// Returns whether action is allowed under budget and emits alerts when exceeded.
    func checkAndRecord(cost deltaUSD: Double, providerId: String, date now: Date = Date()) -> Bool
    {
        guard deltaUSD >= 0, let budget = providerBudgets[providerId] else { return true }

        // Pull usage totals for today/month
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let startOfMonth =
            cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfDay

        let usage = AIUsageStore.shared
        let dayTotals = usage.aggregate(byProviderOnly: true, in: startOfDay...now).filter { $0.providerId == providerId }
        let monthTotals = usage.aggregate(byProviderOnly: true, in: startOfMonth...now).filter {
            $0.providerId == providerId
        }

        let dayCost = (dayTotals.first?.estimatedCostUSD ?? 0) + deltaUSD
        let monthCost = (monthTotals.first?.estimatedCostUSD ?? 0) + deltaUSD

        if let d = budget.dailyUSD, dayCost >= d {
            lastAlert = (providerId, "Daily budget exceeded for \(providerId).")
            return !budget.blockOnExceed
        }
        if let m = budget.monthlyUSD, monthCost >= m {
            lastAlert = (providerId, "Monthly budget exceeded for \(providerId).")
            return !budget.blockOnExceed
        }
        return true
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(providerBudgets)
            userDefaults.set(data, forKey: budgetsKey)
        } catch {
            NSLog("⚠️ Failed to persist budgets: \(error)")
        }
    }

    private func load() {
        if let data = userDefaults.data(forKey: budgetsKey) {
            do {
                providerBudgets = try JSONDecoder().decode([String: Budget].self, from: data)
            } catch {
                providerBudgets = [:]
            }
        }
    }
}
