import CoreData
import SwiftUI
import Combine
import os.log

/// Service for managing browser history
/// Handles visit tracking, search, and data management
class HistoryService: ObservableObject {
    static let shared = HistoryService()
    
    private let logger = Logger(subsystem: "com.example.Web", category: "HistoryService")
    private let coreDataStack = CoreDataStack.shared
    
    @Published var recentHistory: [HistoryItem] = []
    @Published var isLoading = false
    
    // Settings
    private let maxHistoryItems = 10000
    private let maxHistoryDays = 365
    
    // UI update management
    private var uiUpdateTask: Task<Void, Never>?
    
    private init() {
        loadRecentHistory()
    }
    
    // MARK: - Visit Tracking
    
    /// Record a visit to a URL
    /// Increments visit count if URL exists, creates new entry if not
    func recordVisit(url: String, title: String?) {
        guard !url.isEmpty && isValidURL(url) else { return }
        
        // Skip private browsing or special URLs
        if shouldExcludeFromHistory(url: url) {
            return
        }
        
        Task {
            do {
                try await coreDataStack.performBackgroundTask { context in
                    if let existingItem = HistoryItem.findByURL(url, context: context) {
                        // Update existing item
                        existingItem.recordVisit()
                        if let title = title, !title.isEmpty {
                            existingItem.title = title
                        }
                        self.logger.debug("Updated existing history item: \(url) (visits: \(existingItem.visitCount))")
                    } else {
                        // Create new item
                        _ = HistoryItem(context: context, url: url, title: title)
                        self.logger.debug("Created new history item: \(url)")
                    }
                }
                
                // Update UI on main thread with debouncing
                await MainActor.run {
                    scheduleUIUpdate()
                }
                
                // Clean up old history periodically
                await cleanupOldHistory()
                
            } catch {
                logger.error("Failed to record visit: \(error.localizedDescription)")
            }
        }
    }
    
    /// Update favicon for a history item
    func updateFavicon(url: String, faviconData: Data) {
        Task {
            do {
                try await coreDataStack.performBackgroundTask { context in
                    if let historyItem = HistoryItem.findByURL(url, context: context) {
                        historyItem.faviconData = faviconData
                        self.logger.debug("Updated favicon for: \(url)")
                    }
                }
            } catch {
                logger.error("Failed to update favicon: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Data Retrieval
    
    /// Load recent history items for UI
    private func loadRecentHistory() {
        do {
            let request = HistoryItem.fetchAllSorted(context: coreDataStack.viewContext)
            request.fetchLimit = 50
            recentHistory = try coreDataStack.viewContext.fetch(request)
        } catch {
            logger.error("Failed to load recent history: \(error.localizedDescription)")
        }
    }
    
    /// Schedule an immediate UI update
    private func scheduleUIUpdate() {
        // Cancel existing update task
        uiUpdateTask?.cancel()
        
        // Update UI immediately
        uiUpdateTask = Task {
            await MainActor.run {
                loadRecentHistory()
            }
        }
    }
    
    /// Search history items matching query
    func searchHistory(query: String) -> [HistoryItem] {
        guard !query.isEmpty else { return recentHistory }
        
        do {
            let request = HistoryItem.fetchMatching(query: query, context: coreDataStack.viewContext)
            request.fetchLimit = 100
            return try coreDataStack.viewContext.fetch(request)
        } catch {
            logger.error("Failed to search history: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Get history items from a specific date range
    func getHistory(from startDate: Date, to endDate: Date) -> [HistoryItem] {
        do {
            let request = HistoryItem.fetchFromDateRange(from: startDate, to: endDate, context: coreDataStack.viewContext)
            return try coreDataStack.viewContext.fetch(request)
        } catch {
            logger.error("Failed to get history from date range: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Get most visited URLs for autofill suggestions
    func getMostVisited(limit: Int = 10) -> [HistoryItem] {
        let request = HistoryItem.fetchAllSorted(context: coreDataStack.viewContext)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \HistoryItem.visitCount, ascending: false),
            NSSortDescriptor(keyPath: \HistoryItem.lastVisitDate, ascending: false)
        ]
        request.fetchLimit = limit
        
        do {
            return try coreDataStack.viewContext.fetch(request)
        } catch {
            logger.error("Failed to get most visited: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Get history grouped by date for UI display
    func getHistoryGroupedByDate() -> [(String, [HistoryItem])] {
        let allHistory = recentHistory
        let groupedHistory = Dictionary(grouping: allHistory) { item in
            if Calendar.current.isDateInToday(item.lastVisitDate) {
                return "Today"
            } else if Calendar.current.isDateInYesterday(item.lastVisitDate) {
                return "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return formatter.string(from: item.lastVisitDate)
            }
        }
        
        return groupedHistory.sorted { first, second in
            if first.key == "Today" { return true }
            if second.key == "Today" { return false }
            if first.key == "Yesterday" { return true }
            if second.key == "Yesterday" { return false }
            return first.key > second.key
        }
    }
    
    // MARK: - Data Management
    
    /// Delete a specific history item with immediate UI feedback
    func deleteHistoryItem(_ item: HistoryItem) {
        let itemID = item.objectID
        let url = item.url
        
        // Immediate UI update - remove from published array first
        recentHistory.removeAll { $0.objectID == itemID }
        
        Task {
            do {
                try await coreDataStack.performBackgroundTask { context in
                    // Fetch the object in the correct context
                    if let objectToDelete = try? context.existingObject(with: itemID) {
                        context.delete(objectToDelete)
                        self.logger.debug("Deleted history item: \(url)")
                    } else {
                        self.logger.warning("Could not find history item to delete: \(url)")
                    }
                }
                
                // Reload from database to ensure consistency
                await MainActor.run {
                    loadRecentHistory()
                }
            } catch {
                logger.error("Failed to delete history item: \(error.localizedDescription)")
                // Revert UI change on error
                await MainActor.run {
                    loadRecentHistory()
                }
            }
        }
    }
    
    /// Delete all history items from a specific date with immediate UI feedback
    func deleteHistory(from date: Date) {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        Task {
            do {
                let itemsToDelete = getHistory(from: startOfDay, to: endOfDay)
                let itemIDs = itemsToDelete.map { $0.objectID }
                
                // Immediate UI update - remove from published array first
                recentHistory.removeAll { item in
                    itemIDs.contains(item.objectID)
                }
                
                try await coreDataStack.performBackgroundTask { context in
                    let request: NSFetchRequest<NSFetchRequestResult> = HistoryItem.fetchRequest()
                    request.predicate = NSPredicate(format: "lastVisitDate >= %@ AND lastVisitDate <= %@", 
                                                  startOfDay as NSDate, endOfDay as NSDate)
                    
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                    deleteRequest.resultType = .resultTypeObjectIDs
                    
                    let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                    let objectIDArray = result?.result as? [NSManagedObjectID] ?? []
                    
                    // Merge changes into view context
                    let changes = [NSDeletedObjectsKey: objectIDArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, 
                                                      into: [self.coreDataStack.viewContext])
                    
                    self.logger.info("Deleted \(objectIDArray.count) history items from \(date)")
                }
                
                // Reload to ensure consistency
                await MainActor.run {
                    loadRecentHistory()
                }
            } catch {
                logger.error("Failed to delete history from date: \(error.localizedDescription)")
                // Revert UI change on error
                await MainActor.run {
                    loadRecentHistory()
                }
            }
        }
    }
    
    /// Clear all history with immediate UI feedback
    func clearAllHistory(completion: ((Bool) -> Void)? = nil) {
        // Immediate UI update - clear published array first
        recentHistory.removeAll()
        
        Task {
            do {
                try await coreDataStack.performBackgroundTask { context in
                    let request: NSFetchRequest<NSFetchRequestResult> = HistoryItem.fetchRequest()
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                    deleteRequest.resultType = .resultTypeObjectIDs
                    
                    let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                    let objectIDArray = result?.result as? [NSManagedObjectID] ?? []
                    
                    // Merge changes into view context for proper cleanup
                    let changes = [NSDeletedObjectsKey: objectIDArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, 
                                                      into: [self.coreDataStack.viewContext])
                    
                    self.logger.info("Cleared \(objectIDArray.count) history items")
                }
                
                // Reload to ensure consistency
                await MainActor.run {
                    loadRecentHistory()
                    completion?(true)
                }
            } catch {
                logger.error("Failed to clear history: \(error.localizedDescription)")
                // Revert UI change on error
                await MainActor.run {
                    loadRecentHistory()
                    completion?(false)
                }
            }
        }
    }
    
    /// Clean up old history items beyond retention limits
    private func cleanupOldHistory() async {
        do {
            try await coreDataStack.performBackgroundTask { context in
                // Delete items older than max days
                let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.maxHistoryDays, to: Date())!
                let oldItemsRequest = HistoryItem.fetchRequest()
                oldItemsRequest.predicate = NSPredicate(format: "lastVisitDate < %@", cutoffDate as NSDate)
                
                let oldItems = try context.fetch(oldItemsRequest)
                for item in oldItems {
                    context.delete(item)
                }
                
                if !oldItems.isEmpty {
                    self.logger.info("Cleaned up \(oldItems.count) old history items")
                }
                
                // If still over limit, delete oldest items
                let totalCountRequest = HistoryItem.fetchRequest()
                let totalCount = try context.count(for: totalCountRequest)
                
                if totalCount > self.maxHistoryItems {
                    let excessCount = totalCount - self.maxHistoryItems
                    let oldestItemsRequest = HistoryItem.fetchAllSorted(context: context)
                    oldestItemsRequest.sortDescriptors = [NSSortDescriptor(keyPath: \HistoryItem.lastVisitDate, ascending: true)]
                    oldestItemsRequest.fetchLimit = excessCount
                    
                    let oldestItems = try context.fetch(oldestItemsRequest)
                    for item in oldestItems {
                        context.delete(item)
                    }
                    
                    self.logger.info("Cleaned up \(excessCount) excess history items")
                }
            }
        } catch {
            logger.error("Failed to cleanup old history: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helper Methods
    
    /// Check if URL should be excluded from history
    private func shouldExcludeFromHistory(url: String) -> Bool {
        let excludedSchemes = ["file://", "data:", "about:", "chrome:", "webkit:"]
        let excludedDomains = ["localhost", "127.0.0.1", "::1"]
        
        for scheme in excludedSchemes {
            if url.hasPrefix(scheme) {
                return true
            }
        }
        
        for domain in excludedDomains {
            if url.contains(domain) {
                return true
            }
        }
        
        return false
    }
    
    /// Basic URL validation
    private func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme != nil && url.host != nil
    }
}

// MARK: - Integration Extensions

extension HistoryService {
    /// Get autofill suggestions for URL bar
    func getAutofillSuggestions(for query: String, limit: Int = 10) -> [HistoryItem] {
        guard !query.isEmpty else { return getMostVisited(limit: limit) }
        
        let searchResults = searchHistory(query: query)
        return Array(searchResults.prefix(limit))
    }
    
    /// Check if URL exists in history
    func containsURL(_ url: String) -> Bool {
        return HistoryItem.findByURL(url, context: coreDataStack.viewContext) != nil
    }
    
    /// Get visit count for URL
    func getVisitCount(for url: String) -> Int32 {
        return HistoryItem.findByURL(url, context: coreDataStack.viewContext)?.visitCount ?? 0
    }
}