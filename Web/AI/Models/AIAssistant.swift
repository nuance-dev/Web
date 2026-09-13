import Combine
import Foundation
import WebKit

/// Main AI Assistant coordinator managing local AI capabilities
/// Integrates MLX framework with context management and conversation handling
@MainActor
class AIAssistant: ObservableObject {

    // MARK: - Published Properties (Main Actor for UI Updates)

    @MainActor @Published var isInitialized: Bool = false
    @Published private(set) var isInitializing = false
    private var initializationTask: (id: UUID, task: Task<Void, Never>)?
    private var initializedConfiguration: String?
    private var requestRevision = 0
    @MainActor @Published var isProcessing: Bool = false
    @MainActor @Published var initializationStatus: String = "Not initialized"
    // Agent timeline state (for Agent mode in the sidebar)
    @MainActor @Published var currentAgentRun: AgentRun?
    @MainActor @Published var lastError: String?

    // UNIFIED ANIMATION STATE - prevents conflicts between typing/streaming indicators
    @MainActor @Published var animationState: AIAnimationState = .idle
    @MainActor @Published var streamingText: String = ""

    // MARK: - Dependencies

    private let mlxWrapper: MLXWrapper
    private let mlxModelService: MLXModelService
    private let privacyManager: PrivacyManager
    private let conversationHistory: ConversationHistory
    private let gemmaService: GemmaService
    private let contextManager: ContextManager
    private let memoryMonitor: SystemMemoryMonitor
    private weak var tabManager: TabManager?
    private let providerManager = AIProviderManager.shared

    // MARK: - Configuration

    private let aiConfiguration: AIConfiguration
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(tabManager: TabManager? = nil) {
        // Initialize dependencies
        self.mlxWrapper = MLXWrapper()
        self.privacyManager = PrivacyManager()
        self.conversationHistory = ConversationHistory()
        self.contextManager = ContextManager.shared
        self.memoryMonitor = SystemMemoryMonitor.shared
        self.tabManager = tabManager

        // Get optimal configuration for current hardware
        self.aiConfiguration = HardwareDetector.getOptimalAIConfiguration()

        // Initialize MLX service and Gemma service after super.init equivalent
        self.mlxModelService = MLXModelService()
        self.gemmaService = GemmaService(
            configuration: aiConfiguration,
            mlxWrapper: mlxWrapper,
            privacyManager: privacyManager,
            mlxModelService: mlxModelService
        )

        setupBindings()

        // Provider loading begins when the assistant is opened.
        AppLog.debug("AI Assistant init: framework=\(aiConfiguration.framework)")
    }

    // MARK: - Public Interface

    /// Get current conversation messages for UI display
    var messages: [ConversationMessage] {
        conversationHistory.getRecentMessages()
    }

    /// Get message count for UI binding
    var messageCount: Int {
        conversationHistory.messageCount
    }

    /// Coalesce callers and report the state of the selected provider, not a spare local runner.
    func initialize() async {
        setupProviderBindingsOnce()
        if let running = initializationTask {
            await running.task.value
            if initializationTask?.id == running.id { initializationTask = nil }
        }
        guard let provider = providerManager.currentProvider else {
            lastError = "Choose a provider in Settings."
            return
        }
        let configuration = "\(provider.providerId):\(provider.selectedModel?.id ?? "")"
        if isInitialized && initializedConfiguration == configuration { return }
        if let running = initializationTask { await running.task.value; return }
        let id = UUID()
        let task = Task { @MainActor in
            isInitializing = true
            isInitialized = false
            lastError = nil
            initializationStatus = "Loading \(provider.displayName)…"
            defer { isInitializing = false }
            do {
                try await provider.initialize()
                guard providerManager.currentProvider?.providerId == provider.providerId else { return }
                initializedConfiguration = "\(provider.providerId):\(provider.selectedModel?.id ?? "")"
                isInitialized = true
                initializationStatus = "Ready"
            } catch {
                guard providerManager.currentProvider?.providerId == provider.providerId else { return }
                lastError = error.localizedDescription
                initializationStatus = "Couldn't load model"
            }
        }
        initializationTask = (id, task)
        await task.value
        if initializationTask?.id == id { initializationTask = nil }
    }

    // MARK: - Agent Planning (M2 minimal)

    /// Plans a sequence of PageAction steps from a natural language query using the current provider.
    func planAgentActions(from query: String) async throws -> [PageAction] {
        guard let provider = providerManager.currentProvider else {
            throw AIError.inferenceError("No AI provider available")
        }

        let schemaSnippet = """
            Output ONLY JSON: an array of objects where each object is a PageAction with keys:
            - type: one of ["navigate","findElements","click","typeText","scroll","select","waitFor","extract"]
            - locator: optional object with keys [role,name,text,css,xpath,near,nth]
            - url: string (for navigate)
            - newTab: boolean (for navigate)
            - text: string (for typeText or waitFor.selector)
            - value: string (for select)
            - direction: string (for scroll; "down"|"up" or "ready" for waitFor.readyState)
            - amountPx: number (for scroll) or delayMs when using waitFor
            - submit: boolean (for typeText)
            - timeoutMs: number (for waitFor)
            Keep actions safe and deterministic. Prefer semantic locators (text/name/role) before css. Do not include prose.
            Example:
            [
              {"type":"navigate","url":"https://www.zara.com","newTab":false},
              {"type":"waitFor","direction":"ready","timeoutMs":8000},
              {"type":"typeText","locator":{"role":"textbox","name":"Search"},"text":"sweater", "submit":true},
              {"type":"waitFor","direction":"ready","timeoutMs":8000},
              {"type":"click","locator":{"text":"Add to cart","nth":0}}
            ]
            """

        let prompt = """
            You are a planning assistant for a browser automation agent. Given the user request, output JSON ONLY containing a PageAction array that is safe and minimal to accomplish the intent on the CURRENT page context. Avoid destructive actions. Prefer steps like waitFor ready-state between navigations and clicks.

            User request:
            \(query)

            \(schemaSnippet)
            """

        let raw = try await provider.generateRawResponse(
            prompt: prompt, model: provider.selectedModel)
        if let plan = Self.decodePlan(from: raw) { return plan }
        throw AIError.inferenceError("Model did not return a valid PageAction JSON plan")
    }

    /// Plans and executes the agent steps with a live timeline.
    func planAndRunAgent(_ query: String) async {
        guard AgentPermissionManager.browserAutomationEnabled else {
            await MainActor.run { self.lastError = "Page automation is unavailable. Ask a question or summarize the page." }
            return
        }
        AppLog.debug("Agent planning requested")
        do {
            // Fast-path: accept dev /plan JSON directly
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var plan: [PageAction]
            if trimmed.hasPrefix("/plan ") {
                let json = String(trimmed.dropFirst(6))
                if let data = json.data(using: .utf8),
                    let parsed = try? JSONDecoder().decode([PageAction].self, from: data)
                {
                    plan = parsed
                } else {
                    throw AIError.inferenceError("Invalid /plan JSON format")
                }
            } else {
                plan = try await planAgentActions(from: query)
            }
            if plan.isEmpty, let fallback = Self.heuristicPlan(for: query) {
                NSLog(
                    "🛰️ Agent: Model returned empty plan, using heuristic fallback plan (\(fallback.count) steps)"
                )
                plan = fallback
            }
            // Site-aware post-processing (e.g., ensure dynamic content has a selector wait)
            plan = Self.postProcessPlanForSites(plan)
            NSLog("🛰️ Agent: Plan decoded with \(plan.count) steps")
            await MainActor.run {
                var steps: [AgentStep] = []
                // Add a leading pseudo-step to show user's instruction in the timeline
                let userStep = AgentStep(
                    id: UUID(),
                    action: PageAction(type: .askUser, text: query),
                    state: .success,
                    message: nil
                )
                steps.append(userStep)
                steps.append(
                    contentsOf: plan.map {
                        AgentStep(id: $0.id, action: $0, state: .planned, message: nil)
                    })
                self.currentAgentRun = AgentRun(
                    id: UUID(), title: query, steps: steps, startedAt: Date(), finishedAt: nil)
            }

            let (maybeWebView, host) = await MainActor.run { () -> (WKWebView?, String?) in
                (self.tabManager?.activeTab?.webView, self.tabManager?.activeTab?.url?.host)
            }
            guard let webView = maybeWebView else {
                await MainActor.run { self.markTimelineFailureForAll(message: "no webview") }
                return
            }

            let agent = PageAgent(webView: webView)
            let requiresChoice = Self.queryImpliesChoice(query)
            for (idx, step) in plan.enumerated() {
                // Policy gate and consent
                let decision = AgentPermissionManager.shared.evaluate(
                    intent: step.type, urlHost: host)
                if !decision.allowed {
                    let consent = await self.callAgentTool(
                        name: "askUser",
                        arguments: [
                            "prompt": "Confirm: \(step.type.rawValue) on \(host ?? "site")?",
                            "choices": ["Allow once", "Cancel"],
                            "default": 1,
                            "timeoutMs": 15000,
                        ])
                    let allowed = consent.ok && ((consent.data?["choiceIndex"]?.value as? Int) == 0)
                    if !allowed {
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: .failure, message: decision.reason ?? "blocked")
                            self.currentAgentRun?.finishedAt = Date()
                        }
                        return
                    }
                }

                await MainActor.run { self.updateTimelineStep(index: idx, state: .running) }
                NSLog("🛰️ Agent: Running step \(idx + 1)/\(plan.count): \(step.type.rawValue)")

                // Observe–act selection when applicable, same as fallback path
                if requiresChoice, step.type == .click, step.locator != nil,
                    step.locator?.nth == nil
                {
                    let preferredRole = step.locator?.role?.lowercased()
                    let primaryLocator = LocatorInput(role: preferredRole ?? "article")
                    var candidates = await agent.requestElements(matching: primaryLocator)
                    if candidates.isEmpty {
                        candidates = await agent.requestElements(
                            matching: LocatorInput(role: "link"))
                    }
                    if !candidates.isEmpty,
                        let pick = await Self.chooseElementIndex(
                            from: candidates, forQuery: query,
                            provider: self.providerManager.currentProvider)
                    {
                        let role = preferredRole ?? (!candidates.isEmpty ? "article" : "link")
                        var ok = await agent.click(locator: LocatorInput(role: role, nth: pick))
                        if !ok {
                            let linkCandidates = await agent.requestElements(
                                matching: LocatorInput(role: "link"))
                            if !linkCandidates.isEmpty,
                                let linkPick = await Self.chooseElementIndex(
                                    from: linkCandidates, forQuery: query,
                                    provider: self.providerManager.currentProvider)
                            {
                                ok = await agent.click(
                                    locator: LocatorInput(role: "link", nth: linkPick))
                            }
                        }
                        if ok {
                            _ = await agent.waitFor(
                                predicate: PageAction(
                                    type: .waitFor, direction: nil, timeoutMs: 3000),
                                timeoutMs: 3000)
                            let content = await agent.extract(readMode: "article", selector: nil)
                            await MainActor.run {
                                self.updateTimelineStep(
                                    index: idx, state: .success,
                                    message: content.isEmpty
                                        ? "clicked choice (no article text)" : "clicked choice")
                            }
                        } else {
                            await MainActor.run {
                                self.updateTimelineStep(
                                    index: idx, state: .failure, message: "click failed")
                            }
                        }
                    } else {
                        let r = (await agent.execute(plan: [step])).first
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: (r?.success == true) ? .success : .failure,
                                message: r?.message)
                        }
                    }
                } else if step.type == .typeText {
                    // Generic input selection: observe → choose → type
                    let inputRole = step.locator?.role?.lowercased() ?? "textbox"
                    var inputs = await agent.requestElements(
                        matching: LocatorInput(role: inputRole))
                    if inputs.isEmpty {
                        inputs = await agent.requestElements(matching: LocatorInput(role: "input"))
                    }
                    let textToType =
                        step.text ?? Self.inferTextToType(from: query, defaultValue: nil) ?? ""
                    if !inputs.isEmpty,
                        let pick = await Self.chooseElementIndex(
                            from: inputs, forQuery: query,
                            provider: self.providerManager.currentProvider)
                    {
                        let ok = await agent.typeText(
                            locator: LocatorInput(role: inputRole, nth: pick),
                            text: textToType,
                            submit: step.submit ?? false)
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: ok ? .success : .failure,
                                message: ok ? "typed into choice #\(pick)" : "type failed")
                        }
                    } else {
                        let r = (await agent.execute(plan: [step])).first
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: (r?.success == true) ? .success : .failure,
                                message: r?.message)
                        }
                    }
                } else {
                    let resultArray = await agent.execute(plan: [step])
                    let r = resultArray.first
                    await MainActor.run {
                        self.updateTimelineStep(
                            index: idx, state: (r?.success == true) ? .success : .failure,
                            message: r?.message)
                    }
                }
            }
            await MainActor.run { self.currentAgentRun?.finishedAt = Date() }
            NSLog("🛰️ Agent: Finished agent run")
        } catch {
            // Try a heuristic plan if planning failed
            if let fallback = Self.heuristicPlan(for: query) {
                NSLog(
                    "🛰️ Agent: Planning failed (\(error.localizedDescription)). Using heuristic fallback plan (\(fallback.count) steps)"
                )
                await MainActor.run {
                    var steps: [AgentStep] = []
                    let userStep = AgentStep(
                        id: UUID(),
                        action: PageAction(type: .askUser, text: query),
                        state: .success,
                        message: nil
                    )
                    steps.append(userStep)
                    steps.append(
                        contentsOf: fallback.map {
                            AgentStep(id: $0.id, action: $0, state: .planned, message: nil)
                        })
                    self.currentAgentRun = AgentRun(
                        id: UUID(), title: query, steps: steps, startedAt: Date(), finishedAt: nil)
                }
                let (maybeWebView, host) = await MainActor.run { () -> (WKWebView?, String?) in
                    (self.tabManager?.activeTab?.webView, self.tabManager?.activeTab?.url?.host)
                }
                guard let webView = maybeWebView else {
                    await MainActor.run { self.markTimelineFailureForAll(message: "no webview") }
                    return
                }
                let agent = PageAgent(webView: webView)
                var adjusted = Self.postProcessPlanForSites(fallback)

                // Passive observe-act enhancement: if the query implies a choice (pick/best/funniest),
                // replace a generic click with an interactive selection driven by element summaries.
                let requiresChoice = Self.queryImpliesChoice(query)
                for (idx, step) in adjusted.enumerated() {
                    let decision = AgentPermissionManager.shared.evaluate(
                        intent: step.type, urlHost: host)
                    if !decision.allowed {
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: .failure, message: decision.reason ?? "blocked")
                            self.currentAgentRun?.finishedAt = Date()
                        }
                        return
                    }

                    await MainActor.run { self.updateTimelineStep(index: idx, state: .running) }
                    NSLog(
                        "🛰️ Agent: (fallback) Running step \(idx + 1)/\(fallback.count): \(step.type.rawValue)"
                    )

                    // Observe -> decide -> act only when applicable and safe.
                    if requiresChoice, step.type == .click, step.locator != nil,
                        step.locator?.nth == nil
                    {
                        // Build a broad candidate locator from the planned locator's role, defaulting to articles then links
                        let preferredRole = step.locator?.role?.lowercased()
                        let primaryLocator = LocatorInput(role: preferredRole ?? "article")
                        var candidates = await agent.requestElements(matching: primaryLocator)
                        if candidates.isEmpty {
                            candidates = await agent.requestElements(
                                matching: LocatorInput(role: "link"))
                        }

                        if !candidates.isEmpty,
                            let pick = await Self.chooseElementIndex(
                                from: candidates, forQuery: query,
                                provider: self.providerManager.currentProvider)
                        {
                            // Execute the chosen click by index using the same role ordering
                            let role = preferredRole ?? (!candidates.isEmpty ? "article" : "link")
                            var ok = await agent.click(locator: LocatorInput(role: role, nth: pick))
                            // If click did not succeed, try link-based candidates once
                            if !ok {
                                let linkCandidates = await agent.requestElements(
                                    matching: LocatorInput(role: "link"))
                                if !linkCandidates.isEmpty,
                                    let linkPick = await Self.chooseElementIndex(
                                        from: linkCandidates, forQuery: query,
                                        provider: self.providerManager.currentProvider)
                                {
                                    ok = await agent.click(
                                        locator: LocatorInput(role: "link", nth: linkPick))
                                }
                            }
                            // After click, opportunistically verify content by extracting article text
                            if ok {
                                _ = await agent.waitFor(
                                    predicate: PageAction(
                                        type: .waitFor, direction: nil, timeoutMs: 3000),
                                    timeoutMs: 3000)
                                let content = await agent.extract(
                                    readMode: "article", selector: nil)
                                // If no content, still mark success but note that navigation may be client-side
                                await MainActor.run {
                                    self.updateTimelineStep(
                                        index: idx, state: .success,
                                        message: content.isEmpty
                                            ? "clicked choice #\(pick) (no article text)"
                                            : "clicked choice #\(pick)")
                                }
                            } else {
                                await MainActor.run {
                                    self.updateTimelineStep(
                                        index: idx, state: .failure,
                                        message: "click failed")
                                }
                            }
                        } else {
                            // Fallback to executing the original step if we cannot decide
                            let r = (await agent.execute(plan: [step])).first
                            await MainActor.run {
                                self.updateTimelineStep(
                                    index: idx, state: (r?.success == true) ? .success : .failure,
                                    message: r?.message ?? "fallback click")
                            }
                        }
                    } else {
                        let r = (await agent.execute(plan: [step])).first
                        await MainActor.run {
                            self.updateTimelineStep(
                                index: idx, state: (r?.success == true) ? .success : .failure,
                                message: r?.message)
                        }
                    }
                }
                await MainActor.run { self.currentAgentRun?.finishedAt = Date() }
                NSLog("🛰️ Agent: Finished heuristic fallback run")
                return
            }

            NSLog("❌ Agent: Planning failed with error: \(error.localizedDescription)")
            await MainActor.run {
                // Surface a visible failure row instead of an empty timeline
                var failureStep = PageAction(type: .askUser)
                let failure = AgentStep(
                    id: failureStep.id, action: failureStep, state: .failure,
                    message: "planning failed")
                self.currentAgentRun = AgentRun(
                    id: UUID(), title: query, steps: [failure], startedAt: Date(),
                    finishedAt: Date())
            }
        }
    }

    // MARK: - Iterative Tool-Use Loop (page-agnostic)
    /// Runs a multi-step, model-directed loop: model observes, decides a tool, we execute, feed results back, repeat.
    /// This uses ToolRegistry semantics and avoids site-specific assumptions. Stops on explicit done, maxSteps, or no-op.
    func runAgentLoop(_ instruction: String, maxSteps: Int = 12) async {
        guard AgentPermissionManager.browserAutomationEnabled else {
            await MainActor.run { self.lastError = "Page automation is unavailable. Ask a question or summarize the page." }
            return
        }
        guard await isInitialized else { return }
        let start = Date()
        let (maybeWebView, host) = await MainActor.run { () -> (WKWebView?, String?) in
            (self.tabManager?.activeTab?.webView, self.tabManager?.activeTab?.url?.host)
        }
        guard let webView = maybeWebView else { return }

        // Initialize timeline
        await MainActor.run {
            let userStep = AgentStep(
                id: UUID(),
                action: PageAction(type: .askUser, text: instruction),
                state: .success,
                message: nil
            )
            self.currentAgentRun = AgentRun(
                id: UUID(),
                title: instruction,
                steps: [userStep],
                startedAt: start,
                finishedAt: nil
            )
        }

        // Conversation frame for the loop
        var scratch: [String] = []

        // One-time lightweight page context for smarter, page-agnostic reasoning
        // Keep this minimal to avoid token bloat
        let pageContext: WebpageContext? = await extractCurrentContext()
        // Detect high-level site hints for guidance (page-agnostic usage only)
        let siteHost = await MainActor.run { self.tabManager?.activeTab?.url?.host?.lowercased() }

        // Optional intent hint derived from heuristic plan (navigation vs on-page typing)
        var intentHint: String? = {
            guard let hintPlan = Self.heuristicPlan(for: instruction) else { return nil }
            if let nav = hintPlan.first(where: { $0.type == .navigate }), let u = nav.url {
                return "suggest:navigate url=\(u)"
            }
            if let type = hintPlan.first(where: { $0.type == .typeText }) {
                let txt = (type.text ?? "").prefix(100)
                return "suggest:typeText submit=\(type.submit == true) text=\(txt)"
            }
            return nil
        }()

        // Helper to append a step
        func appendStep(_ action: PageAction, state: AgentStepState, msg: String?) async {
            await MainActor.run {
                self.currentAgentRun?.steps.append(
                    AgentStep(id: action.id, action: action, state: state, message: msg))
            }
        }

        // Helper to auto-dismiss cookie/consent banners via PageAgent
        func autoDismissConsentIfPresent() async {
            // Cookie consent belongs to the user; never dismiss or accept it automatically.
    }

        // Tool schema for the model
        let toolSchema = """
            Output ONLY JSON for one tool per turn: {"tool":"<name>", "arguments":{...}}
            Return exactly one tool per turn. Do not bundle or chain multiple actions in a single response.
            Tools:
            - navigate(url: string, newTab?: boolean)
            - waitFor(readyState?: "complete" | "ready", selector?: string, delayMs?: number, timeoutMs?: number)
            - findElements(locator?: {role?: string, name?: string, text?: string, css?: string, xpath?: string, near?: string, nth?: number})
            - observe(kinds?: ("interactive"|"articles"|"textboxes")[], limit?: number)  // curated lists for deterministic selection
            - click(locator: Locator)  // when selecting from a prior list, use locator.nth
            - typeText(locator: Locator, text: string, submit?: boolean)  // set submit:true for searches
            - select(locator: Locator, value: string)
            - scroll(locator?: Locator, direction?: "down"|"up", amountPx?: number)
            - extract(readMode?: "selection"|"article"|"all", selector?: string)
            - askUser(prompt: string, choices?: string[], default?: number, timeoutMs?: number)
            - snapshot(locator?: Locator, cropToElement?: boolean)  // optional visual aid when uncertain
            Constraints:
            - Strictly avoid crafting CSS/XPath selectors. Do NOT use locator.css/xpath unless you are echoing an existing successful hint from a prior observation.
            - Prefer role/name/text and indices (locator.nth) when selecting from a sample returned by findElements.
            - Prefer observe() or findElements() to request the exact candidates you need (e.g., articles or textboxes) and then choose by nth.
            - When searching or typing into inputs, first call findElements with role="textbox" (or "input"), then typeText with locator.nth and submit:true if appropriate.
            - Insert waitFor after navigation or form submission before proceeding.
            - Avoid site-specific attributes (e.g., data-click-id, brand-specific classnames). Be page-agnostic.
            - Observations include a State JSON (last_tool_key, same_tool_streak, host, focused element) and optionally LastFind with role, count, and candidate elements. Use these to choose locator.role and locator.nth deterministically.
            - Exactly one tool per turn; if you need more steps, ask for them across subsequent turns.
            - If the instruction includes phrases like "enter", "open", or "go to" followed by a site-like token, prefer navigate over typing into a search box.
            - Avoid site-specific assumptions. Request candidates with observe() or findElements() and then act deterministically using indices.
            Finish with: {"tool":"done", "arguments":{"summary":"..."}}. No prose.
            """

        // Loop
        var consecutiveFailures = 0
        var skippedDuplicateNavigations = 0
        let maxFailures = 3
        var lastSignature: String? = nil
        var stableNoopCount = 0
        let maxNoop = 2
        // Minimal goal tracking to avoid premature "done"
        let needsComment = instruction.lowercased().contains("comment")
        let needsOpenPost =
            instruction.lowercased().contains("post")
            || instruction.lowercased().contains("enter it")
            || instruction.lowercased().contains("open")
        var didAttemptComment = false
        var didOpenPost = false
        var lastToolKey: String? = nil
        var sameToolStreak: Int = 0
        // Persist compact info about the last findElements for the next turn
        var lastFindState: [String: Any]? = nil
        for stepIndex in 0..<(maxSteps + 4) {
            do {
                // On the very first iteration, proactively gather a small element sample to aid planning
                if stepIndex == 0 && scratch.isEmpty {
                    // Generic sample
                    let sample = await self.callAgentTool(name: "findElements", arguments: [:])
                    if let data = sample.data {
                        let count = (data["count"]?.value as? Int) ?? -1
                        let arr = (data["elements"]?.value as? [[String: Any]]) ?? []
                        let previews = arr.prefix(5).compactMap { item in
                            let role = item["role"] as? String ?? ""
                            let name = item["name"] as? String ?? ""
                            let text = item["text"] as? String ?? ""
                            let i = (item["i"] as? Int) ?? 0
                            return "#\(i) role=\(role) name=\(name) text=\(text.prefix(60))"
                        }
                        scratch.append(
                            "auto-findElements: count=\(count) sample=\(previews.joined(separator: "; "))"
                        )
                    }
                    await appendStep(
                        PageAction(type: .findElements), state: sample.ok ? .success : .failure,
                        msg: "auto-observe generic")
                    // Article-specific sample
                    let sampleArticles = await self.callAgentTool(
                        name: "findElements",
                        arguments: [
                            "locator": [
                                "role": "article"
                            ]
                        ])
                    if let data = sampleArticles.data {
                        let count = (data["count"]?.value as? Int) ?? -1
                        let arr = (data["elements"]?.value as? [[String: Any]]) ?? []
                        let previews = arr.prefix(5).compactMap { item in
                            let name = item["name"] as? String ?? ""
                            let text = item["text"] as? String ?? ""
                            let i = (item["i"] as? Int) ?? 0
                            return "#\(i) article name=\(name) text=\(text.prefix(60))"
                        }
                        scratch.append(
                            "auto-findElements(role=article): count=\(count) sample=\(previews.joined(separator: "; "))"
                        )
                    }
                    var step = PageAction(type: .findElements)
                    step.locator = LocatorInput(role: "article")
                    await appendStep(
                        step, state: sampleArticles.ok ? .success : .failure,
                        msg: "auto-observe articles")

                    // Textbox-specific sample (search/login fields, page-agnostic)
                    let sampleTextboxes = await self.callAgentTool(
                        name: "findElements",
                        arguments: [
                            "locator": [
                                "role": "textbox"
                            ]
                        ])
                    if let data = sampleTextboxes.data {
                        let count = (data["count"]?.value as? Int) ?? -1
                        let arr = (data["elements"]?.value as? [[String: Any]]) ?? []
                        let previews = arr.prefix(5).compactMap { item in
                            let name = item["name"] as? String ?? ""
                            let text = item["text"] as? String ?? ""
                            let i = (item["i"] as? Int) ?? 0
                            return "#\(i) textbox name=\(name) text=\(text.prefix(60))"
                        }
                        scratch.append(
                            "auto-findElements(role=textbox): count=\(count) sample=\(previews.joined(separator: "; "))"
                        )
                    }
                    var stepTb = PageAction(type: .findElements)
                    stepTb.locator = LocatorInput(role: "textbox")
                    await appendStep(
                        stepTb, state: sampleTextboxes.ok ? .success : .failure,
                        msg: "auto-observe textboxes")

                    // Attempt to auto-dismiss cookie/consent banners if present
                    await autoDismissConsentIfPresent()

                    // Bootstrap (minimal): at most navigate → waitFor(ready). No eager type/click.
                    if let bootstrap = Self.heuristicPlan(for: instruction), !bootstrap.isEmpty {
                        if let nav = bootstrap.first(where: { $0.type == .navigate }),
                            let u = nav.url
                        {
                            let navObs = await self.callAgentTool(
                                name: "navigate",
                                arguments: [
                                    "url": u,
                                    "newTab": nav.newTab ?? false,
                                ])
                            await appendStep(
                                PageAction(type: .navigate, url: u, newTab: nav.newTab ?? false),
                                state: navObs.ok ? .success : .failure,
                                msg: "bootstrap")
                            if navObs.ok {
                                let waitObs = await self.callAgentTool(
                                    name: "waitFor",
                                    arguments: [
                                        "readyState": "ready",
                                        "timeoutMs": (nav.timeoutMs ?? 10000),
                                    ])
                                var waitAction = PageAction(type: .waitFor)
                                waitAction.direction = "ready"
                                waitAction.timeoutMs = nav.timeoutMs ?? 10000
                                await appendStep(
                                    waitAction,
                                    state: waitObs.ok ? .success : .failure,
                                    msg: "bootstrap")
                            }
                            await autoDismissConsentIfPresent()
                            // Consume navigation intent to prevent repeated navigate prompts
                            intentHint = nil
                        }
                    }
                }
                // Compose observation for the model from last scratch + optional page read
                let contextSnippet: String = {
                    let urlStr = self.tabManager?.activeTab?.url?.absoluteString ?? ""
                    let title = self.tabManager?.activeTab?.title ?? ""
                    var lines: [String] = [
                        "URL: \(urlStr)",
                        "Title: \(title)",
                    ]
                    if let pageContext {
                        let snippet = String(pageContext.text.prefix(400)).replacingOccurrences(
                            of: "\n", with: " ")
                        lines.append("Snippet: \(snippet)")
                    }
                    if let intentHint { lines.append("Intent-hint: \(intentHint)") }
                    return lines.joined(separator: "\n")
                }()

                // Also record current page location in scratch so the model sees it
                if let curUrl = await MainActor.run(body: {
                    self.tabManager?.activeTab?.url?.absoluteString
                }) {
                    scratch.append("page: \(curUrl)")
                }

                // Build a compact, machine-parsable observation block to make reasoning deterministic
                var observationBlocks: [String] = []
                observationBlocks.append("Scratch:\n" + scratch.suffix(10).joined(separator: "\n"))
                observationBlocks.append("Context:\n" + contextSnippet)
                // Prepare host and focused element info (requires await)
                let stateHost = await MainActor.run { self.tabManager?.activeTab?.url?.host }
                var focusedDict: [String: Any]? = nil
                if let webView = await MainActor.run(body: { self.tabManager?.activeTab?.webView })
                {
                    let agent = PageAgent(webView: webView)
                    if let focused = await agent.getFocusedElementSummary() {
                        var f: [String: Any] = [:]
                        f["role"] = focused.role ?? ""
                        f["name"] = focused.name ?? ""
                        f["visible"] = focused.isVisible
                        focusedDict = f
                    }
                }
                // Include a compact state JSON: last tool, streak, host, and focus info
                let stateJson: String = {
                    var dict: [String: Any] = [:]
                    if let last = lastToolKey { dict["last_tool_key"] = last }
                    dict["same_tool_streak"] = sameToolStreak
                    if let h = stateHost { dict["host"] = h }
                    if let f = focusedDict { dict["focused"] = f }
                    if JSONSerialization.isValidJSONObject(dict),
                        let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
                    {
                        return String(data: data, encoding: .utf8) ?? "{}"
                    }
                    return "{}"
                }()
                observationBlocks.append("State:\n" + stateJson)
                if let last = lastFindState {
                    if JSONSerialization.isValidJSONObject(last),
                        let data = try? JSONSerialization.data(withJSONObject: last, options: []),
                        let json = String(data: data, encoding: .utf8)
                    {
                        observationBlocks.append("LastFind:\n" + json)
                    } else {
                        let role = (last["role"] as? String) ?? ""
                        let count = (last["count"] as? Int) ?? 0
                        let elems = (last["elements"] as? [[String: Any]]) ?? []
                        let list = elems.prefix(6).map {
                            let i = ($0["i"] as? Int) ?? 0
                            let r = ($0["role"] as? String) ?? ""
                            let n = ($0["name"] as? String) ?? ""
                            return "#\(i) role=\(r) name=\(n)"
                        }.joined(separator: "; ")
                        observationBlocks.append(
                            "LastFind:\nrole=\(role) count=\(count) sample=\(list)")
                    }
                }
                observationBlocks.append("Instruction:\n" + instruction)
                if let siteHost { observationBlocks.append("Host:\n" + siteHost) }
                let observation = observationBlocks.joined(separator: "\n")

                guard let provider = providerManager.currentProvider else { break }
                let prompt = """
                    You are a careful browser agent. Decide the next action to achieve the goal on an arbitrary webpage. Prefer safe and deterministic steps. If a selector is needed, use accessible roles/names when possible and add waits appropriately.

                    \(toolSchema)

                    Observation:
                    \(observation)
                    """
                // Stronger planning nudge when duplicate navs were seen
                let planningHint =
                    skippedDuplicateNavigations > 0
                    ? "\nHint: Do not navigate again; proceed with on-page actions (findElements/click/typeText)."
                    : ""
                let raw = try await provider.generateRawResponse(
                    prompt: prompt + planningHint, model: provider.selectedModel)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let jsonStart = trimmed.firstIndex(of: "{") else {
                    scratch.append("Model returned non-JSON; retrying")
                    consecutiveFailures += 1
                    if consecutiveFailures >= maxFailures { break }
                    continue
                }
                let jsonOnly = String(trimmed[jsonStart...])
                guard
                    let data = jsonOnly.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tool = obj["tool"] as? String
                else {
                    scratch.append("Model returned invalid tool object; retrying")
                    consecutiveFailures += 1
                    if consecutiveFailures >= maxFailures { break }
                    continue
                }
                var args: [String: Any] = (obj["arguments"] as? [String: Any]) ?? [:]
                // Guardrails: sanitize locator fields to avoid CSS/XPath from model
                if var loc = args["locator"] as? [String: Any] {
                    loc.removeValue(forKey: "css")
                    loc.removeValue(forKey: "xpath")
                    args["locator"] = loc
                }

                // Extract locator role once for this step (used in observations and loop tracking)
                let locatorRole: String? = {
                    if let loc = args["locator"] as? [String: Any] {
                        return (loc["role"] as? String)?.lowercased()
                    }
                    return nil
                }()

                // Debounce duplicate navigations to the same host
                if tool == "navigate" {
                    let currentUrlStr =
                        await MainActor.run { self.tabManager?.activeTab?.url?.absoluteString }
                        ?? ""
                    let currentHost =
                        await MainActor.run { self.tabManager?.activeTab?.url?.host?.lowercased() }
                        ?? ""
                    let targetStr = (args["url"] as? String) ?? ""
                    if let target = URL(string: targetStr) {
                        let targetHost = (target.host ?? "").replacingOccurrences(
                            of: "www.", with: ""
                        ).lowercased()
                        let curHost = currentHost.replacingOccurrences(of: "www.", with: "")
                            .lowercased()
                        if !targetStr.isEmpty
                            && (targetStr == currentUrlStr
                                || (!targetHost.isEmpty && targetHost == curHost))
                        {
                            skippedDuplicateNavigations += 1
                            scratch.append("skip navigate: already on host=\(curHost)")
                            // Convert to a brief ready wait instead
                            let waitObs = await self.callAgentTool(
                                name: "waitFor",
                                arguments: [
                                    "readyState": "ready",
                                    "timeoutMs": 6000,
                                ])
                            var timelineAction = PageAction(type: .waitFor)
                            timelineAction.direction = "ready"
                            await appendStep(
                                timelineAction, state: waitObs.ok ? .success : .failure,
                                msg: "debounce navigate")
                            // After first duplicate, drop any lingering navigate intent hint
                            intentHint = nil
                            // If the model keeps asking to navigate, do not terminate early;
                            // instead strongly hint via scratch to proceed with on-page actions.
                            if skippedDuplicateNavigations >= 2 {
                                scratch.append(
                                    "policy: navigation to current host disabled; choose findElements/click/typeText next"
                                )
                            }
                            continue
                        }
                    }
                }

                if tool == "done" {
                    let summary = (args["summary"] as? String) ?? ""
                    // Guard against finishing too early when explicit tasks remain
                    if (needsComment && !didAttemptComment) || (needsOpenPost && !didOpenPost) {
                        var missing: [String] = []
                        if needsOpenPost && !didOpenPost { missing.append("open a post") }
                        if needsComment && !didAttemptComment { missing.append("type a comment") }
                        scratch.append(
                            "cannot finish: outstanding tasks → \(missing.joined(separator: ", "))")
                        // Provide an element sample to help planning next step
                        let sample = await self.callAgentTool(name: "findElements", arguments: [:])
                        if let data = sample.data {
                            let count = (data["count"]?.value as? Int) ?? -1
                            let arr = (data["elements"]?.value as? [[String: Any]]) ?? []
                            let previews = arr.prefix(5).compactMap { item in
                                let role = item["role"] as? String ?? ""
                                let name = item["name"] as? String ?? ""
                                let text = item["text"] as? String ?? ""
                                let i = (item["i"] as? Int) ?? 0
                                return "#\(i) role=\(role) name=\(name) text=\(text.prefix(60))"
                            }
                            scratch.append(
                                "auto-sample: count=\(count) sample=\(previews.joined(separator: "; "))"
                            )
                        }
                        continue
                    }
                    scratch.append("Done: \(summary)")
                    break
                }

                // Policy gate
                let mappedIntent: PageActionType? = {
                    switch tool {
                    case "navigate": return .navigate
                    case "findElements": return .findElements
                    case "observe": return .findElements
                    case "click": return .click
                    case "typeText": return .typeText
                    case "select": return .select
                    case "scroll": return .scroll
                    case "waitFor": return .waitFor
                    case "extract": return .extract
                    case "askUser": return .askUser
                    default: return nil
                    }
                }()

                if let intent = mappedIntent {
                    let decision = AgentPermissionManager.shared.evaluate(
                        intent: intent, urlHost: host)
                    if !decision.allowed {
                        // Try consent
                        let consent = await self.callAgentTool(
                            name: "askUser",
                            arguments: [
                                "prompt": "Allow action: \(intent.rawValue) on \(host ?? "site")?",
                                "choices": ["Allow once", "Cancel"],
                                "default": 1,
                                "timeoutMs": 15000,
                            ])
                        let allowed =
                            consent.ok && ((consent.data?["choiceIndex"]?.value as? Int) == 0)
                        if !allowed {
                            scratch.append("Blocked by policy: \(decision.reason ?? "")")
                            break
                        }
                    }
                }

                // Execute tool
                let result = await self.callAgentTool(name: tool, arguments: args)
                if let data = result.data {
                    let keys = data.keys.sorted()
                    if tool == "findElements" || tool == "observe" {
                        let count = (data["count"]?.value as? Int) ?? -1
                        let sample = (data["elements"]?.value as? [[String: Any]]) ?? []
                        let previews = sample.prefix(5).compactMap { item in
                            let role = item["role"] as? String ?? ""
                            let name = item["name"] as? String ?? ""
                            let text = item["text"] as? String ?? ""
                            let i = (item["i"] as? Int) ?? 0
                            return "#\(i) role=\(role) name=\(name) text=\(text.prefix(60))"
                        }
                        let tag = (tool == "observe") ? "observe" : "findElements"
                        scratch.append(
                            "\(tag): \(result.ok ? "ok" : "fail") count=\(count) sample=\(previews.joined(separator: "; "))"
                        )
                        // Persist a compact lastFind for the next turn in a machine-readable form
                        let compactItems: [[String: Any]] = sample.prefix(8).map { item in
                            var obj: [String: Any] = [:]
                            obj["i"] = (item["i"] as? Int) ?? 0
                            obj["role"] = (item["role"] as? String) ?? ""
                            obj["name"] = (item["name"] as? String) ?? ""
                            return obj
                        }
                        let initialRole = ((args["locator"] as? [String: Any])?["role"] as? String)?
                            .lowercased()
                        var roleEcho: String = initialRole ?? ""
                        if let locEcho = data["locator"]?.value as? [String: Any],
                            let r = locEcho["role"] as? String, !r.isEmpty
                        {
                            roleEcho = r
                        }
                        lastFindState = [
                            "role": roleEcho,
                            "count": count,
                            "elements": compactItems,
                        ]
                        // Nudge model to act deterministically (reduce find loops)
                        if count > 0 {
                            let suggestedRole =
                                roleEcho.isEmpty ? (initialRole ?? (locatorRole ?? "")) : roleEcho
                            if !suggestedRole.isEmpty {
                                scratch.append(
                                    "hint: choose an index and call click with locator.role=\(suggestedRole) and locator.nth=<index> next"
                                )
                            } else {
                                scratch.append(
                                    "hint: choose an index and call click with locator.nth=<index> next"
                                )
                            }
                        }
                    } else if tool == "extract" {
                        let t = (data["text"]?.value as? String) ?? ""
                        scratch.append("extract: \(result.ok ? "ok" : "fail") len=\(t.count)")
                    } else {
                        scratch.append("\(tool): \(result.ok ? "ok" : "fail") dataKeys=\(keys)")
                    }
                } else {
                    // Enrich observations for tools without data by echoing locator and args when present
                    if let loc = args["locator"] as? [String: Any] {
                        let r = (loc["role"] as? String) ?? ""
                        let n = (loc["nth"] as? Int)
                        let name = (loc["name"] as? String) ?? (loc["text"] as? String) ?? ""
                        let sel = [r, name].filter { !$0.isEmpty }.joined(separator: ":")
                        let nthStr = n != nil ? " nth=\(n!)" : ""
                        scratch.append(
                            "\(tool): \(result.ok ? "ok" : "fail") locator=\(sel)\(nthStr) \(result.message ?? "")"
                        )
                    } else {
                        scratch.append(
                            "\(tool): \(result.ok ? "ok" : "fail") \(result.message ?? "")")
                    }
                }

                // Record a timeline step for visibility
                var timelineAction = PageAction(type: mappedIntent ?? .askUser)
                if let loc = args["locator"] {  // pass-through for debug display only
                    if let data = try? JSONSerialization.data(withJSONObject: loc),
                        let decoded = try? JSONDecoder().decode(LocatorInput.self, from: data)
                    {
                        timelineAction.locator = decoded
                    }
                }
                await appendStep(
                    timelineAction, state: result.ok ? .success : .failure, msg: result.message)

                // If repeated failures, stop
                if !result.ok { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
                if consecutiveFailures >= maxFailures { break }

                // Track repeated tool pattern to detect findElements loops
                let toolKey = tool + "|" + (locatorRole ?? "")
                if let last = lastToolKey, last == toolKey {
                    sameToolStreak += 1
                } else {
                    sameToolStreak = 1
                    lastToolKey = toolKey
                }

                // If stuck repeating findElements/observe with the same role, add a strong hint to proceed
                if tool == "findElements" || tool == "observe", sameToolStreak >= 2 {
                    let r = locatorRole ?? (lastFindState?["role"] as? String) ?? ""
                    if !r.isEmpty {
                        scratch.append(
                            "policy: repeated \(tool) detected; select one candidate and call click with locator.role=\(r) and locator.nth=<index>"
                        )
                    } else {
                        scratch.append(
                            "policy: repeated \(tool) detected; select one candidate and call click with locator.nth=<index>"
                        )
                    }
                }

                // Post-action verification: detect unchanged page signatures to avoid no-op loops
                func computePageSignature() async -> String {
                    let curUrl =
                        await MainActor.run { self.tabManager?.activeTab?.url?.absoluteString }
                        ?? ""
                    let curTitle = await MainActor.run { self.tabManager?.activeTab?.title } ?? ""
                    let ext = await self.callAgentTool(
                        name: "extract", arguments: ["readMode": "article"])
                    let text = (ext.data?["text"]?.value as? String) ?? ""
                    let snippet = String(text.prefix(1200))
                    return curUrl + "\n" + curTitle + "\n" + snippet
                }

                // Update basic goal tracking flags
                if result.ok {
                    if tool == "typeText" {
                        let submitFlag = (args["submit"] as? Bool) ?? false
                        if needsComment && !submitFlag { didAttemptComment = true }
                    } else if tool == "click" {
                        didOpenPost = true
                    }
                }
                if ["navigate", "click", "typeText", "select"].contains(tool) {
                    let sig = await computePageSignature()
                    if let last = lastSignature, last == sig {
                        stableNoopCount += 1
                        scratch.append("no-op: page signature unchanged (\(stableNoopCount))")
                        if stableNoopCount >= maxNoop {
                            scratch.append(
                                "hint: signature unchanged twice; prefer scroll or findElements(role=article) before repeating."
                            )
                            // Auto attach a fresh sample to guide the model
                            let sample = await self.callAgentTool(
                                name: "findElements", arguments: [:])
                            if let data = sample.data {
                                let count = (data["count"]?.value as? Int) ?? -1
                                let arr = (data["elements"]?.value as? [[String: Any]]) ?? []
                                let previews = arr.prefix(5).compactMap { item in
                                    let role = item["role"] as? String ?? ""
                                    let name = item["name"] as? String ?? ""
                                    let text = item["text"] as? String ?? ""
                                    let i = (item["i"] as? Int) ?? 0
                                    return "#\(i) role=\(role) name=\(name) text=\(text.prefix(60))"
                                }
                                scratch.append(
                                    "auto-sample: count=\(count) sample=\(previews.joined(separator: "; "))"
                                )
                            }
                        }
                    } else {
                        stableNoopCount = 0
                        lastSignature = sig
                    }
                }

                // Remove site-specific autopilot behaviors to remain page-agnostic; rely on model to request observe/find/inspect
            } catch {
                scratch.append("Loop error: \(error.localizedDescription)")
                break
            }
        }

        await MainActor.run { self.currentAgentRun?.finishedAt = Date() }
        NSLog("🛰️ Agent: Finished agent loop")
    }

    /// Lightweight intent detection: does the query imply choosing one item (e.g., funniest/best/top)?
    private static func queryImpliesChoice(_ query: String) -> Bool {
        let q = query.lowercased()
        let triggers = [
            "pick", "choose", "funniest", "funny", "best", "top", "most upvoted", "most popular",
        ]
        return triggers.contains { q.contains($0) }
    }

    /// Ask the model to choose a single index from candidate element summaries. Returns 0-based index.
    private static func chooseElementIndex(
        from candidates: [ElementSummary], forQuery query: String, provider: AIProvider?
    ) async -> Int? {
        guard let provider = provider else { return nil }
        // Prepare a compact list the model can reason over deterministically
        let maxItems = min(15, candidates.count)
        var lines: [String] = []
        for i in 0..<maxItems {
            let item = candidates[i]
            let role = item.role ?? ""
            let name = (item.name ?? "").replacingOccurrences(of: "\n", with: " ")
            let text = (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
            let snippet = String((name + " " + text).prefix(220))
            lines.append("\(i) | role=\(role) | \(snippet)")
        }
        let listBlock = lines.joined(separator: "\n")
        let prompt = """
            You are helping select the best candidate element for a user request. Choose exactly one index from the list.
            - Return ONLY the index as an integer (0-based). No prose, no JSON.
            - Consider the user intent: \(query)
            Candidates (index | role | snippet):
            \(listBlock)
            Answer with a single integer index only.
            """
        do {
            let out = try await provider.generateRawResponse(
                prompt: prompt, model: provider.selectedModel
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            // Extract first integer in the response
            if let match = out.range(of: "-?\\d{1,3}", options: .regularExpression) {
                let token = String(out[match])
                if let idx = Int(token), idx >= 0, idx < maxItems { return idx }
            }
        } catch {}
        return nil
    }

    /// Infer text to type when user says "enter <text>" without a target
    private static func inferTextToType(from query: String, defaultValue: String?) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        if lower.hasPrefix("enter ") {
            let raw = String(q.dropFirst("enter ".count))
            // Stop at common sequencing words
            let stops = [",", ";", ".", " then", " and", " into", " in "]
            var slice = raw
            for s in stops {
                if let r = slice.range(of: s, options: [.caseInsensitive]) {
                    slice = String(slice[..<r.lowerBound])
                    break
                }
            }
            let term = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty ? defaultValue : term
        }
        return defaultValue
    }

    /// Insert generic waits for dynamic content surfaces (agnostic; remove site-specific heuristics)
    private static func postProcessPlanForSites(_ plan: [PageAction]) -> [PageAction] {
        var out: [PageAction] = []
        func genericIdleWait(timeout: Int = 6000) -> PageAction {
            // Encoded as waitFor; PageAgent.waitFor performs network-idle detection as a final phase
            return PageAction(type: .waitFor, direction: nil, timeoutMs: timeout)
        }
        func preSelectorWait(from locator: LocatorInput?) -> PageAction? {
            guard let loc = locator else { return nil }
            if let css = loc.css, !css.isEmpty {
                return PageAction(type: .waitFor, text: css, timeoutMs: 8000)
            }
            if let role = loc.role, !role.isEmpty {
                let sel: String
                switch role.lowercased() {
                case "textbox", "input", "searchbox":
                    sel = "input, textarea, [contenteditable=true], [role=textbox]"
                case "button": sel = "button, [role=button]"
                case "link": sel = "a, [role=link]"
                case "select": sel = "select"
                case "article", "post":
                    // Generic article-like containers only (page-agnostic)
                    sel = "article, [role=article]"
                default: sel = "[role]"
                }
                return PageAction(type: .waitFor, text: sel, timeoutMs: 8000)
            }
            return nil
        }
        for (idx, step) in plan.enumerated() {
            out.append(step)
            if step.type == .navigate {
                let next = (idx + 1) < plan.count ? plan[idx + 1] : nil
                if !(next?.type == .waitFor
                    && (next?.direction == "ready" || (next?.text?.isEmpty == false)))
                {
                    out.append(PageAction(type: .waitFor, direction: "ready", timeoutMs: 10000))
                }
                out.append(genericIdleWait())
            }
            if step.type == .click || step.type == .findElements || step.type == .typeText
                || step.type == .select
            {
                if let wait = preSelectorWait(from: step.locator) {
                    out.removeLast()
                    out.append(wait)
                    out.append(step)
                }
                out.append(genericIdleWait(timeout: 4000))
            }
        }
        return out
    }

    @MainActor private func markTimelineFailureForAll(message: String) {
        guard var run = currentAgentRun else { return }
        for i in run.steps.indices {
            run.steps[i].state = .failure
            run.steps[i].message = message
        }
        run.finishedAt = Date()
        currentAgentRun = run
    }

    @MainActor private func updateTimelineStep(
        index: Int, state: AgentStepState, message: String? = nil
    ) {
        guard var run = currentAgentRun, index < run.steps.count else { return }
        run.steps[index].state = state
        if let message { run.steps[index].message = message }
        currentAgentRun = run
    }

    private static func decodePlan(from raw: String) -> [PageAction]? {
        // Try direct decode
        if let data = raw.data(using: .utf8),
            let plan = try? JSONDecoder().decode([PageAction].self, from: data)
        {
            return plan
        }
        // Strip code fences
        let stripped = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(
            of: "```", with: "")
        if let data = stripped.data(using: .utf8),
            let plan = try? JSONDecoder().decode([PageAction].self, from: data)
        {
            return plan
        }
        // Extract first JSON array substring
        if let start = raw.firstIndex(of: "[") {
            if let end = raw.lastIndex(of: "]"), end >= start {
                let slice = raw[start...end]
                if let data = String(slice).data(using: .utf8),
                    let plan = try? JSONDecoder().decode([PageAction].self, from: data)
                {
                    return plan
                }
            }
        }
        return nil
    }

    // MARK: - Heuristic plan (safety-first)
    private static func heuristicPlan(for query: String) -> [PageAction]? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = raw.lowercased()

        // Utility: extract a likely site token immediately following an imperative like "enter/open/go to"
        func extractSiteToken(after prefix: String) -> String? {
            guard q.hasPrefix(prefix) else { return nil }
            let remainder = raw.dropFirst(prefix.count)
            if remainder.isEmpty { return nil }
            // Stop at punctuation or the word boundaries like ",", "then", "and"
            let stopTokens: [String] = [",", ";", ".", " then", " and", " so", " to "]
            var slice = String(remainder)
            for tok in stopTokens {
                if let r = slice.range(of: tok, options: [.caseInsensitive]) {
                    slice = String(slice[..<r.lowerBound])
                    break
                }
            }
            // Trim and keep only domain-like characters
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
            let filtered = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .prefix { allowed.contains($0) }
            let candidate = String(filtered)
            if candidate.isEmpty { return nil }
            return candidate
        }

        func looksLikeDomain(_ token: String) -> Bool {
            if token.hasPrefix("http") || token.hasPrefix("www.") { return true }
            if token.contains(".") {
                let parts = token.split(separator: ".").filter { !$0.isEmpty }
                if parts.count >= 2, parts.last!.count >= 2 { return true }
            }
            // Common site names to improve UX without hardcoding behavior per site
            let knownSites: Set<String> = [
                "reddit", "youtube", "google", "github", "twitter", "x", "facebook",
                "instagram", "amazon", "apple", "medium", "wikipedia", "bing",
                "netflix", "linkedin", "figma", "notion", "webflow", "vercel", "linear",
            ]
            return knownSites.contains(token)
        }

        func normalizeUrl(from token: String) -> String {
            var t = token
            if !t.contains(".") { t += ".com" }
            if !t.hasPrefix("http") { t = "https://" + t }
            return t
        }

        // Extract a search term if present
        func extractSearchTerm(_ q: String, original: String) -> String? {
            let patterns = [
                "search for ",
                "search ",
                "look up ",
                "find ",
            ]
            var term: String?
            for p in patterns {
                if q.contains(p) {
                    if let r = q.range(of: p) {
                        let startIdx = original.index(
                            original.startIndex,
                            offsetBy: q.distance(from: q.startIndex, to: r.upperBound))
                        var slice = String(original[startIdx...])
                        // stop tokens
                        let stops: [String] = [",", ";", ".", " then", " and", " on ", " in "]
                        for s in stops {
                            if let r2 = slice.range(of: s, options: [.caseInsensitive]) {
                                slice = String(slice[..<r2.lowerBound])
                                break
                            }
                        }
                        term = slice.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
            return term?.isEmpty == true ? nil : term
        }

        // Heuristic A: Navigation intents including "enter <site>"
        if let token = extractSiteToken(after: "enter ")
            ?? extractSiteToken(after: "open ")
            ?? extractSiteToken(after: "go to ")
            ?? extractSiteToken(after: "navigate to ")
        {
            // Only treat as navigation if it looks like a site/domain; otherwise fall through to search heuristic
            guard looksLikeDomain(token) else { return nil }
            let url = normalizeUrl(from: token)

            // Optional follow-on search term
            let searchTerm = extractSearchTerm(q, original: raw)
            // If the remainder suggests selecting an article/post, click the first article-like item generically
            let mentionsFunny = q.contains("funniest") || q.contains("funny")
            let wantsComment = q.contains("comment") || q.contains("write a comment")
            var actions: [PageAction] = [
                PageAction(type: .navigate, url: url, newTab: false),
                PageAction(type: .waitFor, direction: "ready", timeoutMs: 10000),
            ]
            if let term = searchTerm, !term.isEmpty {
                actions.append(
                    PageAction(
                        type: .typeText, locator: LocatorInput(role: "textbox"), text: term,
                        submit: true))
                actions.append(PageAction(type: .waitFor, direction: "ready", timeoutMs: 10000))
            }
            // Generic content selection (site-agnostic): click an article/post
            var articleLocator = LocatorInput(role: "article")
            if mentionsFunny { articleLocator.text = "funny" }
            actions.append(PageAction(type: .click, locator: articleLocator))
            actions.append(PageAction(type: .waitFor, direction: "ready", timeoutMs: 10000))
            if wantsComment {
                let commentText =
                    inferCommentText(from: raw) ?? "😂 This cracked me up — thanks for sharing!"
                actions.append(
                    PageAction(
                        type: .typeText, locator: LocatorInput(role: "textbox"), text: commentText,
                        submit: false))
            }
            return actions
        }

        // Heuristic B: On-page search queries
        if q.hasPrefix("search ") || q.hasPrefix("search for ") || q.hasPrefix("look up ")
            || q.hasPrefix("find ")
        {
            var term =
                q
                .replacingOccurrences(of: "search for ", with: "")
                .replacingOccurrences(of: "search ", with: "")
                .replacingOccurrences(of: "look up ", with: "")
                .replacingOccurrences(of: "find ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty { return nil }
            let locator = LocatorInput(role: "textbox")
            var actions: [PageAction] = [
                PageAction(type: .waitFor, direction: "ready", timeoutMs: 8000),
                PageAction(type: .typeText, locator: locator, text: term, submit: true),
                PageAction(type: .waitFor, direction: "ready", timeoutMs: 8000),
            ]
            if q.contains("comment") {
                let commentText =
                    inferCommentText(from: raw) ?? "😂 This cracked me up — thanks for sharing!"
                actions.append(
                    PageAction(
                        type: .typeText, locator: LocatorInput(role: "textbox"), text: commentText,
                        submit: false))
            }
            return actions
        }

        // Heuristic C: "enter <query>" when not a domain/site => treat as typing into a textbox
        if q.hasPrefix("enter ") {
            let remainder = raw.dropFirst("enter ".count)
            var term = String(remainder)
            // Stop at common sequencing words
            if let r = term.range(of: ",") { term = String(term[..<r.lowerBound]) }
            if let r = term.range(of: " then", options: [.caseInsensitive]) {
                term = String(term[..<r.lowerBound])
            }
            term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                let locator = LocatorInput(role: "textbox")
                return [
                    PageAction(type: .waitFor, direction: "ready", timeoutMs: 8000),
                    PageAction(type: .typeText, locator: locator, text: term, submit: true),
                    PageAction(type: .waitFor, direction: "ready", timeoutMs: 8000),
                ]
            }
        }

        return nil
    }

    /// Generate a lighthearted comment if the instruction requests one
    private static func inferCommentText(from query: String) -> String? {
        let q = query.lowercased()
        guard q.contains("comment") else { return nil }
        // Keep this short and friendly to avoid spammy behavior
        let options = [
            "😂 This cracked me up — thanks for sharing!",
            "🤣 Can't stop laughing — this is gold.",
            "😄 This made my day!",
            "😂 Peak comedy right here.",
        ]
        return options.randomElement()
    }

    /// Process a user query with current context and optional history
    func processQuery(_ query: String, includeContext: Bool = true, includeHistory: Bool = true)
        async throws -> AIResponse
    {
        guard await isInitialized else {
            throw AIError.notInitialized
        }

        let revision = requestRevision
        guard let provider = providerManager.currentProvider else { throw AIError.notInitialized }

        AppLog.debug("AI Chat: Processing query (includeContext=\(includeContext))")

        // MEMORY SAFETY: Check if AI operations are safe to perform
        guard memoryMonitor.isAISafeToRun() else {
            let memoryStatus = memoryMonitor.getCurrentMemoryStatus()
            throw AIError.memoryPressure(
                "AI operations suspended due to \(memoryStatus.pressureLevel.rawValue.lowercased()) memory pressure (\(String(format: "%.1f", memoryStatus.availableMemory))GB available)"
            )
        }

        Task { @MainActor in isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }

        do {
            // Extract context from current webpage with optional history
            let webpageContext = includeContext ? await extractCurrentContext() : nil
            if let webpageContext = webpageContext {
                AppLog.debug(
                    "AI Chat: Extracted context: \(webpageContext.text.count) chars, q=\(webpageContext.contentQuality)"
                )
                if includeContext && isContentTooGarbled(webpageContext.text) {
                    AppLog.debug("AI Chat: Page content noisy; using title-only context")
                }
            } else {
                AppLog.debug("AI Chat: No webpage context extracted")
            }

            let context =
                includeContext && webpageContext != nil
                ? await contextManager.getFormattedContext(
                    from: webpageContext, includeHistory: includeHistory) : nil
            if let context = context {
                AppLog.debug("AI Chat: Using formatted context (\(context.count) chars)")
            } else {
                AppLog.debug("AI Chat: No context provided to model")
            }

            // Create conversation entry
            let userMessage = ConversationMessage(
                role: .user,
                content: query,
                timestamp: Date(),
                contextData: context
            )

            // Process with current provider
            try validateRequest(revision)
            let response = try await provider.generateResponse(
                query: query,
                context: context,
                conversationHistory: conversationHistory.getRecentMessages(limit: 10),
                model: provider.selectedModel
            )

            try validateRequest(revision)
            conversationHistory.addMessage(userMessage)

            // Create AI response message
            let aiMessage = ConversationMessage(
                role: .assistant,
                content: response.text,
                timestamp: Date(),
                metadata: response.metadata
            )

            // Add to conversation history
            conversationHistory.addMessage(aiMessage)

            // Return response
            return response

        } catch {
            AppLog.error("Query processing failed: \(error.localizedDescription)")
            await handleAIError(error)
            throw error
        }
    }

    /// Process a streaming query with real-time responses and optional history
    func processStreamingQuery(
        _ query: String, includeContext: Bool = true, includeHistory: Bool = true
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard await isInitialized else {
                        throw AIError.notInitialized
                    }

                    let revision = requestRevision
                    guard let provider = providerManager.currentProvider else { throw AIError.notInitialized }
                    isProcessing = true
                    defer { Task { @MainActor in isProcessing = false } }

                    // Extract context from current webpage with optional history
                    let webpageContext = includeContext ? await self.extractCurrentContext() : nil
                    if let webpageContext = webpageContext {
                        AppLog.debug(
                            "Streaming: context=\(webpageContext.text.count) q=\(webpageContext.contentQuality)"
                        )
                    } else {
                        AppLog.debug("Streaming: No webpage context extracted")
                    }

                    let context = includeContext && webpageContext != nil
                        ? await self.contextManager.getFormattedContext(from: webpageContext, includeHistory: includeHistory)
                        : nil
                    if let context = context {
                        AppLog.debug("Streaming: formatted context=\(context.count)")
                    } else {
                        AppLog.debug("Streaming: No formatted context returned")
                    }

                    // Process with current provider
                    try validateRequest(revision)
                    let stream = try await provider.generateStreamingResponse(
                        query: query,
                        context: context,
                        conversationHistory: conversationHistory.getRecentMessages(limit: 10),
                        model: provider.selectedModel
                    )

                    try validateRequest(revision)

                    // Add user message first
                    let userMessage = ConversationMessage(
                        role: .user,
                        content: query,
                        timestamp: Date(),
                        contextData: context
                    )
                    conversationHistory.addMessage(userMessage)

                    // CRITICAL FIX: Add empty AI message for UI streaming but will be updated
                    let aiMessage = ConversationMessage(
                        role: .assistant,
                        content: "",  // Start empty for streaming
                        timestamp: Date()
                    )
                    conversationHistory.addMessage(aiMessage)

                    // Set up unified streaming animation state
                    await MainActor.run {
                        animationState = .streaming(messageId: aiMessage.id)
                        streamingText = ""
                    }

                    var fullResponse = ""
                    let fullResponseBox = Box("")

                    for try await chunk in stream {
                        try validateRequest(revision)
                        fullResponseBox.value += chunk
                        fullResponse = fullResponseBox.value

                        // Update UI streaming text
                        await MainActor.run {
                            streamingText = fullResponseBox.value
                        }

                        continuation.yield(chunk)
                    }

                    // Update the empty message with the final streamed content
                    conversationHistory.updateMessage(id: aiMessage.id, newContent: fullResponse)

                    // Clear unified animation state when done
                    await MainActor.run {
                        animationState = .idle
                        streamingText = ""
                        // Ensure processing flag resets so UI updates status correctly
                        self.isProcessing = false
                    }

                    continuation.finish()

                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        let partial = await streamingText
                        let messageID = await animationState.streamingMessageId
                        if let messageID {
                            conversationHistory.updateMessage(id: messageID, newContent: partial.isEmpty ? "Stopped." : partial)
                        }
                        await MainActor.run {
                            animationState = .idle
                            streamingText = ""
                            isProcessing = false
                        }
                        continuation.finish()
                        return
                    }
                    AppLog.error("Streaming error: \(error.localizedDescription)")

                    // Get the message ID before clearing state
                    let messageId = await animationState.streamingMessageId

                    // Clear unified animation state on error
                    await MainActor.run {
                        animationState = .idle
                        streamingText = ""
                    }

                    // If we have a partially complete message, update it with error info
                    if let messageId = messageId {
                        conversationHistory.updateMessage(
                            id: messageId,
                            newContent:
                                "Sorry, there was an error generating the response: \(error.localizedDescription)"
                        )
                    }

                    await self.handleAIError(error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    // MARK: - Agent Tool Execution
    /// Execute a provider-agnostic tool call object via `ToolRegistry` against the active tab's webview.
    private func executeToolCall(_ call: ToolRegistry.ToolCall) async
        -> ToolRegistry.ToolObservation
    {
        guard let webView = await MainActor.run(body: { self.tabManager?.activeTab?.webView })
        else {
            return ToolRegistry.ToolObservation(
                name: call.name, ok: false, data: nil, message: "no webview")
        }
        return await ToolRegistry.shared.executeTool(call, webView: webView)
    }

    /// Execute a plan of `PageAction`s through `PageAgent` on the active tab (headed mode).
    /// Includes a minimal permission gate per action.
    func runAgentPlan(_ plan: [PageAction]) async -> [ActionResult] {
        guard AgentPermissionManager.browserAutomationEnabled else {
            return plan.map { ActionResult(actionId: $0.id, success: false, message: "Page automation is unavailable.") }
        }
        let (maybeWebView, host) = await MainActor.run { () -> (WKWebView?, String?) in
            let currentHost = self.tabManager?.activeTab?.url?.host
            return (self.tabManager?.activeTab?.webView, currentHost)
        }
        guard let webView = maybeWebView else { return [] }

        let agent = PageAgent(webView: webView)
        var gatedPlan: [PageAction] = []
        for step in plan {
            let decision = AgentPermissionManager.shared.evaluate(intent: step.type, urlHost: host)
            if decision.allowed {
                gatedPlan.append(step)
                AgentAuditLog.shared.append(
                    host: host,
                    action: step.type.rawValue,
                    parameters: summarize(step),
                    policyAllowed: true,
                    policyReason: nil,
                    requestedConsent: false,
                    userConsented: nil,
                    outcomeSuccess: nil,
                    outcomeMessage: nil
                )
            } else {
                AgentAuditLog.shared.append(
                    host: host,
                    action: step.type.rawValue,
                    parameters: summarize(step),
                    policyAllowed: false,
                    policyReason: decision.reason,
                    requestedConsent: true,
                    userConsented: nil,
                    outcomeSuccess: nil,
                    outcomeMessage: nil
                )

                let consent = await callAgentTool(
                    name: "askUser",
                    arguments: [
                        "prompt": "Confirm: \(step.type.rawValue) on \(host ?? "site")?",
                        "choices": ["Allow once", "Cancel"],
                        "default": 1,
                        "timeoutMs": 15000,
                    ]
                )
                let userConsented =
                    consent.ok && ((consent.data?["choiceIndex"]?.value as? Int) == 0)
                AgentAuditLog.shared.append(
                    host: host,
                    action: step.type.rawValue,
                    parameters: summarize(step),
                    policyAllowed: false,
                    policyReason: decision.reason,
                    requestedConsent: true,
                    userConsented: userConsented,
                    outcomeSuccess: nil,
                    outcomeMessage: userConsented ? "user allowed" : "user canceled"
                )

                if userConsented {
                    gatedPlan.append(step)
                } else {
                    let failure = ActionResult(
                        actionId: step.id, success: false, message: decision.reason ?? "blocked")
                    var partial: [ActionResult] = []
                    if !gatedPlan.isEmpty {
                        let prior = await agent.execute(plan: gatedPlan)
                        partial.append(contentsOf: prior)
                    }
                    partial.append(failure)
                    return partial
                }
            }
        }
        let results = await agent.execute(plan: gatedPlan)
        for (idx, step) in gatedPlan.enumerated() {
            let r = (idx < results.count) ? results[idx] : nil
            AgentAuditLog.shared.append(
                host: host,
                action: step.type.rawValue,
                parameters: summarize(step),
                policyAllowed: true,
                policyReason: nil,
                requestedConsent: false,
                userConsented: nil,
                outcomeSuccess: r?.success,
                outcomeMessage: r?.message
            )
        }
        return results
    }

    /// Convenience: call an agent tool by name with arguments on the active tab.
    /// Example names: navigate, findElements, click, typeText, select, scroll, waitFor.
    func callAgentTool(name: String, arguments: [String: Any]) async -> ToolRegistry.ToolObservation
    {
        guard AgentPermissionManager.browserAutomationEnabled else {
            return ToolRegistry.ToolObservation(name: name, ok: false, data: nil, message: "Page automation is unavailable.")
        }
        // Minimal intent classification: map tool name to PageActionType for policy check
        let intent: PageActionType? = {
            switch name {
            case "navigate": return .navigate
            case "findElements": return .findElements
            case "click": return .click
            case "typeText": return .typeText
            case "select": return .select
            case "scroll": return .scroll
            case "waitFor": return .waitFor
            case "extract": return .extract
            case "switchTab": return .switchTab
            case "askUser": return .askUser
            default: return nil
            }
        }()

        let host = await MainActor.run { self.tabManager?.activeTab?.url?.host }
        if let intent = intent {
            let decision = AgentPermissionManager.shared.evaluate(intent: intent, urlHost: host)
            guard decision.allowed else {
                return ToolRegistry.ToolObservation(
                    name: name, ok: false, data: nil, message: decision.reason ?? "blocked")
            }
        }

        let wrappedArgs = arguments.mapValues { AnyCodable($0) }
        let call = ToolRegistry.ToolCall(name: name, arguments: wrappedArgs)
        return await executeToolCall(call)
    }

    // MARK: - Helpers
    private func summarize(_ step: PageAction) -> [String: String] {
        var dict: [String: String] = [:]
        if let url = step.url { dict["url"] = url }
        if let t = step.text { dict["text"] = String(t.prefix(80)) }
        if let v = step.value { dict["value"] = v }
        if let dir = step.direction { dict["direction"] = dir }
        if let amt = step.amountPx { dict["amountPx"] = String(amt) }
        if let submit = step.submit { dict["submit"] = submit ? "true" : "false" }
        if let loc = step.locator {
            var l: [String] = []
            if let role = loc.role { l.append("role=\(role)") }
            if let name = loc.name { l.append("name=\(name)") }
            if let text = loc.text { l.append("text=\(text.prefix(40))") }
            if let css = loc.css { l.append("css=\(css.prefix(40))") }
            if let nth = loc.nth { l.append("nth=\(nth)") }
            dict["locator"] = l.joined(separator: " ")
        }
        return dict
    }

    /// Get conversation summary for the current session
    func getConversationSummary() async throws -> String {
        let messages = conversationHistory.getRecentMessages(limit: 20)
        guard let provider = providerManager.currentProvider else {
            throw AIError.inferenceError("No AI provider available")
        }
        return try await provider.summarizeConversation(messages, model: provider.selectedModel)
    }

    /// Generate TL;DR summary of current page content without affecting conversation history
    func generatePageTLDR() async throws -> String {
        guard await isInitialized else {
            throw AIError.notInitialized
        }

        // CONCURRENCY SAFETY: Check if AI is already processing to avoid conflicts
        let currentlyProcessing = await MainActor.run { isProcessing }
        guard !currentlyProcessing else {
            throw AIError.inferenceError("AI is currently busy with another task")
        }

        // MEMORY SAFETY: Check if AI operations are safe to perform
        guard memoryMonitor.isAISafeToRun() else {
            let memoryStatus = memoryMonitor.getCurrentMemoryStatus()
            throw AIError.memoryPressure(
                "AI operations suspended due to \(memoryStatus.pressureLevel.rawValue.lowercased()) memory pressure (\(String(format: "%.1f", memoryStatus.availableMemory))GB available)"
            )
        }

        // Extract context from current webpage
        let webpageContext = await extractCurrentContext()
        guard let context = webpageContext, !context.text.isEmpty else {
            AppLog.warn("TL;DR: No context available")
            throw AIError.contextProcessingFailed("No content available to summarize")
        }

        // Check for low-quality content that would confuse the model
        if isContentTooGarbled(context.text) {
            AppLog.debug("TL;DR: Content appears garbled; simplifying")
            return
                "📄 Page content detected but contains mostly code/markup. Unable to generate meaningful summary."
        }

        AppLog.debug(
            "TL;DR: Using context (len=\(context.text.count), q=\(context.contentQuality))")

        // Create clean, direct TL;DR prompt - simplified for better model performance
        let cleanedContent = cleanContentForTLDR(context.text)
        let tldrPrompt = """
            Summarize this webpage in 3 bullet points:

            Title: \(context.title)
            Content: \(cleanedContent)

            Format:
            • point 1
            • point 2  
            • point 3
            """

        do {
            // Use current provider RAW prompt generation to avoid chat template noise
            guard let provider = providerManager.currentProvider else {
                throw AIError.inferenceError("No AI provider available")
            }
            let cleanResponse = try await provider.generateRawResponse(
                prompt: tldrPrompt, model: provider.selectedModel
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            // VALIDATION: Check for repetitive or broken output
            if isInvalidTLDRResponse(cleanResponse) {
                AppLog.debug("TL;DR: Invalid response; retrying")

                // Fallback with simpler prompt
                let simplifiedContent = cleanContentForTLDR(context.text)
                let fallbackPrompt =
                    "Summarize this webpage in 2-3 bullet points:\n\nTitle: \(context.title)\nContent: \(simplifiedContent)"
                let fallbackClean = try await provider.generateRawResponse(
                    prompt: fallbackPrompt, model: provider.selectedModel
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                // If fallback is still invalid, attempt a final post-processing pass that collapses
                // repeated phrases to salvage the summary before giving up.
                if isInvalidTLDRResponse(fallbackClean) {
                    AppLog.debug("TL;DR: Fallback invalid; attempting salvage")
                    let salvaged = gemmaService.postProcessForTLDR(fallbackClean)
                    if isInvalidTLDRResponse(salvaged) {
                        AppLog.debug("TL;DR: All attempts failed; returning fallback message")
                        // IMPROVED: Give a more informative message instead of generic error
                        return
                            "📄 Page content detected but summary generation encountered issues. Try refreshing the page."
                    }
                    return salvaged
                }

                return fallbackClean
            } else {
                AppLog.debug("TL;DR: Success on first attempt")
            }

            return cleanResponse

        } catch {
            AppLog.error("TL;DR generation failed: \(error.localizedDescription)")
            throw AIError.inferenceError("Failed to generate TL;DR: \(error.localizedDescription)")
        }
    }

    /// Generate TL;DR summary of current page content with streaming support
    /// This provides real-time feedback like chat messages for better UX
    func generatePageTLDRStreaming() -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    guard await isInitialized else {
                        throw AIError.notInitialized
                    }

                    // CONCURRENCY SAFETY: Check if AI is already processing to avoid conflicts
                    let currentlyProcessing = await MainActor.run { isProcessing }
                    guard !currentlyProcessing else {
                        throw AIError.inferenceError("AI is currently busy with another task")
                    }

                    // MEMORY SAFETY: Check if AI operations are safe to perform
                    guard memoryMonitor.isAISafeToRun() else {
                        let memoryStatus = memoryMonitor.getCurrentMemoryStatus()
                        throw AIError.memoryPressure(
                            "AI operations suspended due to \(memoryStatus.pressureLevel.rawValue.lowercased()) memory pressure (\(String(format: "%.1f", memoryStatus.availableMemory))GB available)"
                        )
                    }

                    // Extract context from current webpage
                    let webpageContext = await extractCurrentContext()
                    guard let context = webpageContext, !context.text.isEmpty else {
                        AppLog.warn("TL;DR Streaming: No context available")
                        throw AIError.contextProcessingFailed("No content available to summarize")
                    }

                    AppLog.debug(
                        "TL;DR Streaming: Using context len=\(context.text.count) q=\(context.contentQuality)"
                    )

                    // Create clean, direct TL;DR prompt - simplified for better streaming performance
                    let cleanedContent = cleanContentForTLDR(context.text)
                    let tldrPrompt = """
                        Summarize this webpage in 3 bullet points:

                        Title: \(context.title)
                        Content: \(cleanedContent)

                        Format:
                        • point 1
                        • point 2  
                        • point 3
                        """

                    // Log full TLDR prompt for debugging

                    // Use current provider streaming response with post-processing for TL;DR
                    guard let provider = providerManager.currentProvider else {
                        throw AIError.inferenceError("No AI provider available")
                    }
                    let stream = try await provider.generateStreamingResponse(
                        query: tldrPrompt,
                        context: nil,
                        conversationHistory: [],
                        model: provider.selectedModel
                    )

                    var accumulatedResponse = ""
                    var hasYieldedContent = false

                    // Stream the response with real-time updates
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        accumulatedResponse += chunk
                        hasYieldedContent = true

                        // Yield each chunk for real-time display
                        continuation.yield(chunk)
                    }

                    // Post-process the final accumulated response
                    let finalResponse = accumulatedResponse.trimmingCharacters(
                        in: .whitespacesAndNewlines)

                    // If we got a response but it's invalid, try to salvage it
                    if !finalResponse.isEmpty && isInvalidTLDRResponse(finalResponse) {
                        AppLog.debug("TL;DR Streaming: Invalid response; post-processing")
                        let salvaged = gemmaService.postProcessForTLDR(finalResponse)

                        if !isInvalidTLDRResponse(salvaged) && salvaged != finalResponse {
                            // Send the difference as a correction
                            let correction = salvaged.replacingOccurrences(
                                of: finalResponse, with: "")
                            if !correction.isEmpty {
                                continuation.yield(correction)
                            }
                        }
                    }

                    // If no content was streamed, provide a helpful fallback
                    if !hasYieldedContent {
                        AppLog.debug("TL;DR Streaming: No content; yielding fallback")
                        continuation.yield(
                            "📄 Page content detected but summary generation is processing...")
                    }

                    continuation.finish()
                    AppLog.debug("TL;DR Streaming completed (len=\(accumulatedResponse.count))")

                } catch {
                    AppLog.error("TL;DR Streaming failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// Check if content is too garbled with JavaScript/HTML to be useful
    private func isContentTooGarbled(_ content: String) -> Bool {
        let lowercased = content.lowercased()
        let totalLength = content.count

        if AppLog.isVerboseEnabled {
            AppLog.debug("Checking source quality (\(totalLength) characters)")
        }

        // Check for high ratio of JavaScript/HTML artifacts - be more aggressive
        let jsPatterns = [
            "function", "var ", "let ", "const ", "document.", "window.", "console.",
            ".js", "(){", "});", "@keyframes", "html[", "div>", "span>",
            "}.}", "@media", "Date()", "google=", "window=", "getElementById",
            "innerHTML", "addEventListener", "querySelector", "textContent",
        ]

        var jsCount = 0
        var detectedPatterns: [String] = []

        for pattern in jsPatterns {
            let count = lowercased.components(separatedBy: pattern).count - 1
            if count > 0 {
                jsCount += count
                detectedPatterns.append("\(pattern)(\(count))")
            }
        }

        // Also check for excessive punctuation that indicates code
        let punctuationChars = content.filter { "{}();.,=[]".contains($0) }
        let punctuationRatio = Double(punctuationChars.count) / Double(max(totalLength, 1))

        // Check for lack of readable words
        let words = content.components(separatedBy: .whitespacesAndNewlines)
            .filter { word in
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                return trimmed.count >= 3 && trimmed.rangeOfCharacter(from: .letters) != nil
            }
        let readableWordsRatio = Double(words.count * 5) / Double(max(totalLength, 1))  // Avg word length

        let jsRatio = Double(jsCount * 8) / Double(max(totalLength, 1))  // Multiply by avg pattern length

        // More aggressive thresholds
        let isGarbage =
            jsRatio > 0.08  // Reduced from 0.15 to 0.08
            || punctuationRatio > 0.3 || readableWordsRatio < 0.2 || totalLength < 50  // Reduced from 100

        if AppLog.isVerboseEnabled {
            AppLog.debug(
                "Garbage analysis: js=\(jsRatio), punct=\(punctuationRatio), readable=\(readableWordsRatio), len=\(totalLength), patterns=\(detectedPatterns.joined(separator: ", ")), isGarbage=\(isGarbage)"
            )
        }

        return isGarbage
    }

    /// Clean and prepare content specifically for TLDR generation
    private func cleanContentForTLDR(_ content: String) -> String {
        var cleaned = content

        if AppLog.isVerboseEnabled { AppLog.debug("Clean input: len=\(content.count)") }

        // AGGRESSIVE cleaning for the specific garbage we're seeing
        let aggressivePatterns = [
            // Remove the specific garbage patterns we see in logs
            ("\\}\\.[\\}\\w]+", ""),  // }.} patterns
            ("html\\[dir='[^']*'\\]", ""),  // html[dir='rtl']
            ("@keyframes[^\\s]*", ""),  // @keyframes
            ("\\(\\)[\\;\\)\\{\\}]*", ""),  // ()(); patterns
            ("document\\([^\\)]*\\)", ""),  // document() calls
            ("Date\\(\\)[\\;\\}]*", ""),  // Date(); patterns
            ("@media[^\\}]*\\}", ""),  // CSS @media rules
            ("\\{[^\\}]*\\}", ""),  // Any remaining {...} blocks
            ("\\([^\\)]*\\)\\s*\\{", ""),  // function() { patterns
            ("var\\s+[^\\;\\s]*", ""),  // var declarations
            ("function\\s*[^\\{]*\\{", ""),  // function declarations
            ("window\\s*=\\s*[^\\;]*", ""),  // window assignments
            ("google\\s*=\\s*[^\\;]*", ""),  // google assignments
            ("[\\w]+\\[\\w+\\]\\s*=", ""),  // array/object assignments
            ("\\s*;\\s*", " "),  // semicolons
            ("\\s*,\\s*", " "),  // commas
            ("\\&[a-zA-Z]+;", ""),  // HTML entities
            ("<[^>]*>", ""),  // HTML tags - CRITICAL FIX
            ("trackPageView\\(\\)", ""),  // tracking functions
        ]

        var removedCount = 0
        for (pattern, replacement) in aggressivePatterns {
            let before = cleaned.count
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
            let removed = before - cleaned.count
            if removed > 0 {
                removedCount += removed
                if AppLog.isVerboseEnabled {
                    AppLog.debug("Pattern removed: \(pattern) -> \(removed)")
                }
            }
        }

        if AppLog.isVerboseEnabled { AppLog.debug("Total removed: \(removedCount)") }

        // Clean up multiple spaces and normalize
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter to actual readable words only
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { word in
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                // Keep words that are mostly letters and at least 2 chars
                return trimmed.count >= 2 && trimmed.rangeOfCharacter(from: .letters) != nil
                    && !trimmed.contains("{") && !trimmed.contains("}") && !trimmed.contains("(")
                    && !trimmed.contains(")") && !trimmed.contains("=") && !trimmed.contains(";")
            }

        cleaned = words.joined(separator: " ")

        if AppLog.isVerboseEnabled { AppLog.debug("After word filter len=\(cleaned.count)") }

        // Limit length for better model performance
        if cleaned.count > 600 {  // Reduced from 800 for better performance
            cleaned = String(cleaned.prefix(600))
            if AppLog.isVerboseEnabled { AppLog.debug("Truncated to 600 chars") }
        }

        if AppLog.isVerboseEnabled { AppLog.debug("Clean final len=\(cleaned.count)") }
        return cleaned
    }

    /// Check if TL;DR response contains repetitive or invalid patterns
    private func isInvalidTLDRResponse(_ response: String) -> Bool {
        let lowercased = response.lowercased()

        if AppLog.isVerboseEnabled { AppLog.debug("TLDR validation: len=\(response.count)") }

        // Check for repetitive patterns that indicate model confusion
        let badPatterns = [
            "understand",
            "i'll help",
            "please provide",
            "let me know",
            "what can i do",
        ]

        // If response is too short (but allow shorter responses)
        if response.count < 5 {
            AppLog.debug("TLDR validation: too short (\(response.count))")
            return true
        }

        // Detect obvious HTML or code fragments which indicate a bad summary
        if lowercased.contains("<html") || lowercased.contains("<div")
            || lowercased.contains("<span")
        {
            return true
        }

        // IMPROVED: Only flag as invalid if there are MANY repeated adjacent words
        // Allow some repetition but catch excessive cases
        let wordRepetitionPattern = "\\b(\\w+)(\\s+\\1){3,}\\b"  // 4+ repetitions instead of 2+
        if lowercased.range(of: wordRepetitionPattern, options: .regularExpression) != nil {
            AppLog.debug("TLDR validation: word repetition")
            return true
        }

        // IMPROVED: Only flag phrase repetition if it's very excessive (5+ times instead of 3+)
        // This allows some natural repetition while catching obvious loops
        let phrasePattern = "(\\b(?:\\w+\\s+){2,5}\\w+\\b)(?:\\s+\\1){4,}"  // 5+ repetitions instead of 3+
        if lowercased.range(of: phrasePattern, options: [.regularExpression]) != nil {
            AppLog.debug("TLDR validation: phrase repetition")
            return true
        }

        // NEW: Check if response is ONLY repetitive content (more than 80% repetitive)
        let words = lowercased.components(separatedBy: .whitespacesAndNewlines).filter {
            !$0.isEmpty
        }
        if words.count > 5 {
            let uniqueWords = Set(words)
            let repetitionRatio = Double(words.count - uniqueWords.count) / Double(words.count)
            if repetitionRatio > 0.8 {
                AppLog.debug("TLDR validation: high repetition ratio \(repetitionRatio)")
                return true
            }
        }

        // Check for excessive repetition of bad patterns (only if multiple patterns present)
        var badPatternCount = 0
        for pattern in badPatterns {
            if lowercased.contains(pattern) {
                badPatternCount += 1
            }
        }
        if badPatternCount >= 2 {  // Only reject if multiple bad patterns present
            AppLog.debug("TLDR validation: multiple bad patterns \(badPatternCount)")
            return true
        }

        if AppLog.isVerboseEnabled { AppLog.debug("TLDR validation: passed") }
        return false
    }

    /// Clear conversation history and context
    func clearConversation() {
        requestRevision += 1
        conversationHistory.clear()

        // OPTIMIZATION: Also reset MLXRunner conversation state
        Task {
            await providerManager.currentProvider?.resetConversation()
        }

        AppLog.debug("Conversation cleared")
    }

    /// Reset AI conversation state to recover from errors
    func resetConversationState() async {
        // Clear conversation history
        conversationHistory.clear()

        // Reset provider conversation state to prevent KV cache issues
        await providerManager.currentProvider?.resetConversation()

        await MainActor.run {
            lastError = nil
            isProcessing = false
        }

        AppLog.debug("AI conversation state reset")
    }

    /// Handle AI errors with automatic recovery
    private func handleAIError(_ error: Error) async {
        let errorMessage = error.localizedDescription
        AppLog.error("AI Error: \(errorMessage)")

        await MainActor.run {
            lastError = errorMessage
            isProcessing = false
        }

        // Auto-recovery for common errors
        if errorMessage.contains("inconsistent sequence positions")
            || errorMessage.contains("KV cache") || errorMessage.contains("decode")
        {
            AppLog.debug("Detected conversation state error; auto-recover")
            await resetConversationState()
        }
    }

    /// Check if AI system is in a healthy state
    func performHealthCheck() async -> Bool {
        do {
            // Test if the AI system can handle a simple query
            let testQuery = "Hello"
            let _ = try await processQuery(testQuery, includeContext: false)
            return true
        } catch {
            AppLog.warn("AI Health check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Configure history context settings
    @MainActor
    func configureHistoryContext(enabled: Bool, scope: HistoryContextScope) {
        contextManager.configureHistoryContext(enabled: enabled, scope: scope)
        AppLog.debug("History context configured: enabled=\(enabled) scope=\(scope.displayName)")
    }

    /// Get current history context status
    @MainActor
    func getHistoryContextStatus() -> (enabled: Bool, scope: HistoryContextScope) {
        return (contextManager.isHistoryContextEnabled, contextManager.historyContextScope)
    }

    /// Clear history context for privacy
    @MainActor
    func clearHistoryContext() {
        contextManager.clearHistoryContextCache()
        AppLog.debug("History context cleared")
    }

    /// Get current system status
    @MainActor func getSystemStatus() -> AISystemStatus {
        let historyContextInfo = getHistoryContextStatus()

        return AISystemStatus(
            isInitialized: isInitialized,
            framework: aiConfiguration.framework,
            modelVariant: aiConfiguration.modelVariant,
            memoryUsage: Int(mlxWrapper.memoryUsage),
            inferenceSpeed: mlxWrapper.inferenceSpeed,
            contextTokenCount: 0,  // Context processing will be added in Phase 11
            conversationLength: conversationHistory.messageCount,
            hardwareInfo: HardwareDetector.processorType.description,
            historyContextEnabled: historyContextInfo.enabled,
            historyContextScope: historyContextInfo.scope.displayName
        )
    }

    // MARK: - Private Methods
    private var hasSetupProviderBinding = false
    private func setupProviderBindingsOnce() {
        guard !hasSetupProviderBinding else { return }
        hasSetupProviderBinding = true
        providerManager.$currentProvider
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Prior responses can contain page data. Never carry them across providers.
                self.requestRevision += 1
                self.conversationHistory.clear()
                self.isInitialized = false
                Task { await self.initialize() }
            }
            .store(in: &cancellables)
    }

    private func extractCurrentContext() async -> WebpageContext? {
        guard let tabManager = tabManager else {
            NSLog("⚠️ TabManager not available for context extraction")
            return nil
        }

        guard let tab = tabManager.activeTab, !tab.isIncognito else { return nil }
        if let external = providerManager.currentProvider as? ExternalAPIProvider,
           !AIContextPolicy.canSharePage(providerID: external.providerId, isPrivate: tab.isIncognito) {
            return nil
        }
        return await contextManager.extractCurrentPageContext(from: tabManager)
    }

    private func validateHardware() throws {
        switch aiConfiguration.framework {
        case .mlx:
            guard HardwareDetector.isAppleSilicon else {
                throw AIError.unsupportedHardware("MLX requires Apple Silicon")
            }
        case .llamaCpp:
            // Intel Macs supported with llama.cpp
            break
        }

        guard HardwareDetector.totalMemoryGB >= 8 else {
            throw AIError.insufficientMemory("Minimum 8GB RAM required")
        }
    }

    @MainActor
    private func setupBindings() {
        NotificationCenter.default.publisher(for: .aiPageSharingChanged)
            .sink { [weak self] _ in self?.clearConversation() }
            .store(in: &cancellables)
        conversationHistory.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func validateRequest(_ revision: Int) throws {
        try Task.checkCancellation()
        guard revision == requestRevision else { throw CancellationError() }
    }

    private func updateStatus(_ status: String) async {
        initializationStatus = status
        if AppLog.isVerboseEnabled { AppLog.debug("AI Status: \(status)") }
    }
}

// MARK: - Supporting Types

/// Unified animation state for AI responses to prevent conflicts
enum AIAnimationState: Equatable {
    case idle
    case typing
    case streaming(messageId: String)
    case processing

    var isActive: Bool {
        switch self {
        case .idle:
            return false
        case .typing, .streaming, .processing:
            return true
        }
    }

    var isStreaming: Bool {
        if case .streaming = self {
            return true
        }
        return false
    }

    var streamingMessageId: String? {
        if case .streaming(let messageId) = self {
            return messageId
        }
        return nil
    }
}

/// AI system status information
struct AISystemStatus {
    let isInitialized: Bool
    let framework: AIConfiguration.Framework
    let modelVariant: AIConfiguration.ModelVariant
    let memoryUsage: Int  // MB
    let inferenceSpeed: Double  // tokens/second
    let contextTokenCount: Int
    let conversationLength: Int
    let hardwareInfo: String
    let historyContextEnabled: Bool
    let historyContextScope: String
}

// MARK: - Agent timeline models (UI-facing)
enum AgentStepState: String, Codable, Equatable {
    case planned
    case running
    case success
    case failure
}

struct AgentStep: Identifiable, Codable, Equatable {
    let id: UUID
    var action: PageAction
    var state: AgentStepState
    var message: String?
}

struct AgentRun: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var steps: [AgentStep]
    var startedAt: Date
    var finishedAt: Date?
}

extension AgentStep {
    static func == (lhs: AgentStep, rhs: AgentStep) -> Bool {
        return lhs.id == rhs.id && lhs.state == rhs.state && lhs.message == rhs.message
    }
}

extension AgentRun {
    static func == (lhs: AgentRun, rhs: AgentRun) -> Bool {
        return lhs.id == rhs.id && lhs.title == rhs.title && lhs.steps == rhs.steps
            && lhs.finishedAt == rhs.finishedAt
    }
}

/// AI specific errors
enum AIError: LocalizedError {
    case notInitialized
    case unsupportedHardware(String)
    case insufficientMemory(String)
    case memoryPressure(String)
    case modelNotAvailable
    case contextProcessingFailed(String)
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "AI Assistant not initialized"
        case .unsupportedHardware(let message):
            return "Unsupported Hardware: \(message)"
        case .insufficientMemory(let message):
            return "Insufficient Memory: \(message)"
        case .memoryPressure(let message):
            return "Memory Pressure: \(message)"
        case .modelNotAvailable:
            return "AI model not available"
        case .contextProcessingFailed(let message):
            return "Context Processing Failed: \(message)"
        case .inferenceError(let message):
            return "Inference Error: \(message)"
        }
    }
}

/// Conversation message roles
enum ConversationRole: String, Codable {
    case user
    case assistant
    case system
}
