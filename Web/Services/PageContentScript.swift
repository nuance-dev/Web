import Foundation

enum PageContentScript {
    /// No observers, page state, form values, scrolling or unbounded quality scoring.
    static let source = #"""
    (() => {
        const root = document.querySelector('article') || document.querySelector('main, [role="main"]') || document.body;
        const limit = 24000;
        const deadline = performance.now() + 50;
        const excluded = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'FORM', 'INPUT', 'TEXTAREA', 'SELECT', 'BUTTON', 'NAV', 'FOOTER']);
        const headings = [], links = [], chunks = [];
        let length = 0, visited = 0;
        function hidden(element) {
            if (excluded.has(element.tagName) || element.hidden || element.isContentEditable || element.getAttribute('aria-hidden') === 'true') return true;
            const style = getComputedStyle(element);
            return style.display === 'none' || style.visibility === 'hidden';
        }
        let blockedRoot = !root;
        let ancestors = 0;
        for (let ancestor = root; ancestor; ancestor = ancestor.parentElement) {
            if (++ancestors > 256 || performance.now() > deadline || hidden(ancestor)) { blockedRoot = true; break; }
        }
        if (!blockedRoot) {
            const budgetReached = {};
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode(node) {
                    visited++;
                    if (visited > 4000 || performance.now() > deadline) throw budgetReached;
                    if (node.nodeType === Node.ELEMENT_NODE) return hidden(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            let node;
            try {
            while (visited <= 4000 && length < limit && performance.now() <= deadline && (node = walker.nextNode())) {
                if (node.nodeType === Node.TEXT_NODE) {
                    const text = (node.nodeValue || '').slice(0, limit - length).replace(/\s+/g, ' ').trim();
                    if (text) { chunks.push(text); length += text.length + 1; }
                }
            }
            } catch (error) { if (error !== budgetReached) throw error; }
        }
        const text = chunks.join('\n').slice(0, limit);
        return { text, title: document.title.slice(0, 500), url: location.href, headings, links,
            extractionMethod: 'bounded-page-text', contentQuality: text.length > 100 ? 40 : 0,
            frameworksDetected: [], extractionAttempt: 1, isContentStable: true, shouldRetry: false };
    })();
    """#
}
