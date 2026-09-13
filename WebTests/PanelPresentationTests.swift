import Testing
@testable import Web

struct PanelPresentationTests {
    @Test func panelsRemainInTheirOriginatingWindow() {
        var state = PanelPresentationState()
        state.set(.settings, isPresented: true, in: 11)
        #expect(state.panels(in: 11) == [.settings])
        #expect(state.panels(in: 22).isEmpty)

        // A separate explicit action in another window owns a separate panel.
        state.set(.settings, isPresented: true, in: 22)
        state.set(.settings, isPresented: false, in: 22)
        #expect(state.panels(in: 11) == [.settings])
        #expect(state.panels(in: 22).isEmpty)
    }

    @Test func dismissingCommandsPreservesTheUnderlyingWindowPanel() {
        var state = PanelPresentationState()
        state.set(.settings, isPresented: true, in: 11)
        state.set(.commands, isPresented: true, in: 11)
        state.set(.history, isPresented: true, in: 22)
        state.dismissTopPanel(in: 11)
        #expect(state.panels(in: 11) == [.settings])
        #expect(state.panels(in: 22) == [.history])
        state.dismissTopPanel(in: 11)
        #expect(state.panels(in: 11).isEmpty)
        #expect(state.panels(in: 22) == [.history])
    }

    @Test func closingWindowClearsItsPresentationWithoutAffectingOthers() {
        var state = PanelPresentationState()
        state.set(.downloads, isPresented: true, in: 11)
        state.set(.bookmarks, isPresented: true, in: 22)
        state.closeWindow(11)
        #expect(state.panels(in: 11).isEmpty)
        #expect(state.panels(in: 22) == [.bookmarks])
        state.closeWindow(11)
        #expect(state.panels(in: 22) == [.bookmarks])
    }

    @Test func missingWindowDoesNotCreateOrDismissSomeoneElsesPanel() {
        var state = PanelPresentationState()
        state.set(.settings, isPresented: true, in: 11)
        state.set(.about, isPresented: true, in: nil)
        state.dismissTopPanel(in: nil)
        #expect(state.panels(in: nil).isEmpty)
        #expect(state.panels(in: 11) == [.settings])
    }
}
