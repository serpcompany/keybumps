import AppKit
import Testing
@testable import Keybumps

@MainActor
@Suite("Main window routing without a window")
struct MainWindowRoutingTests {
    @Test("Before the window exists, Settings asks for a reopen that creates it")
    func unconfiguredRouterRequestsTheWindow() {
        var reopenRequests = 0
        let router = MainWindowRouter(activate: {}, openWithoutWindow: { _ in reopenRequests += 1 })

        #expect(router.open())
        #expect(reopenRequests == 1)
    }

    @Test("Once the window has appeared, Settings uses its opener and never reopens the app")
    func configuredRouterUsesTheOpener() {
        var opens = 0
        var reopenRequests = 0
        let router = MainWindowRouter(activate: {}, openWithoutWindow: { _ in reopenRequests += 1 })
        router.configure { opens += 1 }

        #expect(router.open())
        #expect(opens == 1)
        #expect(reopenRequests == 0)
    }

    @Test("A requested reopen lets the app create its window once, then Dock clicks open Quick Search again")
    func reopenRequestIsConsumedOnce() async {
        let mainWindowRouter = MainWindowRouter(activate: {})
        let quickSearchRouter = QuickSearchRouter()
        var quickSearchOpens = 0
        quickSearchRouter.configure { quickSearchOpens += 1 }
        let delegate = AppDelegate(
            quickSearchRouter: quickSearchRouter,
            mainWindowRouter: mainWindowRouter
        )

        mainWindowRouter.requestWindowOnNextReopen()
        #expect(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        #expect(!delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(quickSearchOpens == 1)
    }
}

@MainActor
@Suite("Legacy banner cleanup")
struct LegacyBannerCleanupTests {
    @Test("Old Notification Center banners are cleared once per install")
    func clearsOnce() {
        let defaults = InMemoryDefaults()
        var clears = 0
        AppDelegate.clearLegacyBannersOnce(defaults: defaults) { clears += 1 }
        AppDelegate.clearLegacyBannersOnce(defaults: defaults) { clears += 1 }
        #expect(clears == 1)
    }
}
