import Foundation
import ApplicationServices
import Testing
@testable import HyperDock

private nonisolated final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func observerBagStopsDeliveryAndCanBeClearedTwice() {
    let center = NotificationCenter()
    let name = Notification.Name("HyperDockTests.observer")
    let deliveries = DeliveryCounter()
    let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
        deliveries.increment()
    }
    let bag = NotificationObserverBag()
    bag.insert(token, center: center)

    center.post(name: name, object: nil)
    bag.removeAll()
    bag.removeAll()
    center.post(name: name, object: nil)

    #expect(deliveries.value == 1)
}

@Test func systemTilingIsDisabledOnlyWhileHyperDockSnapOwnsTheGesture() {
    #expect(SystemTiling.shouldDisable(hyperDockDisabled: false, snapEnabled: true,
                                       managerAvailable: true))
    #expect(!SystemTiling.shouldDisable(hyperDockDisabled: false, snapEnabled: true,
                                        managerAvailable: false))
    #expect(!SystemTiling.shouldDisable(hyperDockDisabled: true, snapEnabled: true,
                                        managerAvailable: true))
    #expect(!SystemTiling.shouldDisable(hyperDockDisabled: false, snapEnabled: false,
                                        managerAvailable: true))
}

@Test func rebuiltWindowUsesItsLiveSiblingForSpaceActivation() {
    let candidates = [
        CGS.SpaceActivationTarget(space: 4, windowID: 202, windowArea: 900),
        CGS.SpaceActivationTarget(space: 5, windowID: 303, windowArea: 400),
    ]

    let rebuilt = CGS.preferredActivationTarget(clickedWindowID: 101,
                                                directDestination: nil,
                                                fallbackCandidates: candidates)
    #expect(rebuilt?.windowID == 202)
    #expect(rebuilt?.space == 4)

    let stillLive = CGS.preferredActivationTarget(clickedWindowID: 101,
                                                  directDestination: 6,
                                                  fallbackCandidates: candidates)
    #expect(stillLive?.windowID == 101)
    #expect(stillLive?.space == 6)
}

@Test func unplacedSurfaceMatchingDoesNotDependOnOtherApplicationWindows() {
    let clicked = CGRect(x: 100, y: 100, width: 800, height: 600)
    #expect(CGS.framesDescribeSameSurface(
        CGRect(x: 120, y: 110, width: 780, height: 590), clicked))
    #expect(!CGS.framesDescribeSameSurface(
        CGRect(x: 1200, y: 100, width: 800, height: 600), clicked))
    #expect(!CGS.framesDescribeSameSurface(
        CGRect(x: 100, y: 100, width: 800, height: 20), clicked))
}

@Test func clickHideBarrierSurvivesDuplicateHideAndRejectsReload() {
    var state = PreviewVisibilityState()
    let first = state.beginHide(hasBarrier: true)
    guard case let .start(generation) = first.decision else {
        Issue.record("the first hide must start an animation")
        return
    }
    #expect(first.acceptsBarrier)

    #expect(state.beginHide(hasBarrier: false).decision == .coalesced)
    let duplicateClick = state.beginHide(hasBarrier: true)
    #expect(duplicateClick.decision == .coalesced)
    #expect(!duplicateClick.acceptsBarrier)
    #expect(state.beginShow() == nil)
    let finishedBarrier = state.finishHide(generation: generation)
    #expect(finishedBarrier)
    #expect(state.beginShow() != nil)

    let ordinaryHide = state.beginHide(hasBarrier: false)
    guard case let .start(staleGeneration) = ordinaryHide.decision else {
        Issue.record("an ordinary hide must start")
        return
    }
    #expect(state.beginShow() != nil)
    let finishedStaleHide = state.finishHide(generation: staleGeneration)
    #expect(!finishedStaleHide)
}

@Test func optionalScreenRecordingDoesNotSelectPermissionPollingRate() {
    #expect(Permissions.pollingInterval(hasAccessibility: false) == 1)
    #expect(Permissions.pollingInterval(hasAccessibility: true) == 15)
}

@Test func systemTilingSnapshotPreservesAbsentAndExplicitValuesAndMigratesLegacyOwnership() {
    let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]
    let originals: [Bool?] = [nil, true, false]

    for (index, original) in originals.enumerated() {
        let externalName = "HyperDockTests.system.external.\(UUID().uuidString)"
        let ownerName = "HyperDockTests.system.owner.\(UUID().uuidString)"
        let external = UserDefaults(suiteName: externalName)!
        let owner = UserDefaults(suiteName: ownerName)!
        defer {
            external.removePersistentDomain(forName: externalName)
            owner.removePersistentDomain(forName: ownerName)
        }
        if let original {
            for key in keys { external.set(original, forKey: key) }
        }

        SystemTiling.captureOriginalValuesIfNeeded(from: external, snapshotStore: owner)
        for key in keys { external.set(index.isMultiple(of: 2), forKey: key) }
        SystemTiling.restoreOriginalValues(in: external, snapshotStore: owner)

        for key in keys {
            #expect((external.object(forKey: key) as? Bool) == original)
        }
    }

    let legacyExternalName = "HyperDockTests.system.legacy.external.\(UUID().uuidString)"
    let legacyOwnerName = "HyperDockTests.system.legacy.owner.\(UUID().uuidString)"
    let legacyExternal = UserDefaults(suiteName: legacyExternalName)!
    let legacyOwner = UserDefaults(suiteName: legacyOwnerName)!
    defer {
        legacyExternal.removePersistentDomain(forName: legacyExternalName)
        legacyOwner.removePersistentDomain(forName: legacyOwnerName)
    }
    for key in keys { legacyExternal.set(false, forKey: key) }
    SystemTiling.captureOriginalValuesIfNeeded(from: legacyExternal,
                                               snapshotStore: legacyOwner)
    SystemTiling.migrateLegacyOwnershipIfNeeded(existingInstallation: true,
                                                externalDefaults: legacyExternal,
                                                snapshotStore: legacyOwner)
    for key in keys { #expect(legacyExternal.object(forKey: key) == nil) }
}

@Test func dockSnapshotPreservesExactValuesAndMigratesLegacyOwnership() {
    let delay = "autohide-delay"
    let animation = "autohide-time-modifier"
    let externalName = "HyperDockTests.dock.external.\(UUID().uuidString)"
    let ownerName = "HyperDockTests.dock.owner.\(UUID().uuidString)"
    let external = UserDefaults(suiteName: externalName)!
    let owner = UserDefaults(suiteName: ownerName)!
    defer {
        external.removePersistentDomain(forName: externalName)
        owner.removePersistentDomain(forName: ownerName)
    }
    external.set(0.7, forKey: delay)
    external.set(0.8, forKey: animation)

    DockTweaks.captureAutohideValuesIfNeeded(from: external, snapshotStore: owner)
    external.set(0.0, forKey: delay)
    external.set(0.25, forKey: animation)
    DockTweaks.restoreAutohideValues(in: external, snapshotStore: owner)
    #expect((external.object(forKey: delay) as? Double) == 0.7)
    #expect((external.object(forKey: animation) as? Double) == 0.8)

    external.set(0.0, forKey: delay)
    external.set(0.25, forKey: animation)
    DockTweaks.captureAutohideValuesIfNeeded(from: external, snapshotStore: owner)
    #expect(DockTweaks.migrateLegacyOwnershipIfNeeded(existingInstallation: true,
                                                      externalDefaults: external,
                                                      snapshotStore: owner))
    #expect(external.object(forKey: delay) == nil)
    #expect(external.object(forKey: animation) == nil)
}

@Test func thumbnailCacheEvictsBeforeAdmittingANewWindowAtTheLimit() {
    #expect(ThumbnailEngine.shouldEvict(cacheCount: 64, alreadyContainsWindow: false,
                                        limit: 64))
    #expect(!ThumbnailEngine.shouldEvict(cacheCount: 63, alreadyContainsWindow: false,
                                         limit: 64))
    #expect(!ThumbnailEngine.shouldEvict(cacheCount: 64, alreadyContainsWindow: true,
                                         limit: 64))
}

@Test func interactiveWindowQueriesNeverWaitForOptionalTitleEnrichment() {
    #expect(!WindowIndex.QueryPurpose.interactivePreview.waitsForTitleEnrichment)
    #expect(WindowIndex.QueryPurpose.refreshedSnapshot.waitsForTitleEnrichment)
}

@Test func missionControlNeverReturnsAStaleInactiveAnswerForTheTriggeringEvent() {
    let now = Date()
    #expect(MissionControlDetector.refreshDecision(
        now: now,
        cachedAt: .distantPast,
        cacheLifetime: 0.25
    ) == .measureNow)
    #expect(MissionControlDetector.refreshDecision(
        now: now,
        cachedAt: now.addingTimeInterval(-0.1),
        cacheLifetime: 0.25
    ) == .useCachedValue)
}

@Test func titleSnapshotsAreFreshnessBoundAndOnlyClassifyKnownWindows() {
    let snapshot = WindowIndex.TitleSnapshot(
        titles: [41: "cached title"],
        windowIDs: [41, 42],
        receivedAt: 100,
        sequence: 1
    )

    #expect(snapshot.preferredTitle(
        for: 41,
        windowServerTitle: "live title",
        now: 101,
        maxAgeNanoseconds: 10
    ) == "live title")
    #expect(snapshot.preferredTitle(
        for: 41,
        windowServerTitle: "",
        now: 101,
        maxAgeNanoseconds: 10
    ) == "cached title")
    #expect(snapshot.preferredTitle(
        for: 41,
        windowServerTitle: "",
        now: 111,
        maxAgeNanoseconds: 10
    ).isEmpty)

    #expect(snapshot.canClassifyUntitledWindow(
        42, now: 101, maxAgeNanoseconds: 10
    ))
    #expect(!snapshot.canClassifyUntitledWindow(
        43, now: 101, maxAgeNanoseconds: 10
    ))
    #expect(!snapshot.canClassifyUntitledWindow(
        42, now: 111, maxAgeNanoseconds: 10
    ))

    let unavailableTitles = WindowIndex.TitleSnapshot(
        titles: [:], windowIDs: [42], receivedAt: 100, sequence: 2
    )
    #expect(!unavailableTitles.canClassifyUntitledWindow(
        42, now: 101, maxAgeNanoseconds: 10
    ))
}

@Test func olderTitleSnapshotCannotOverwriteANewerOne() {
    #expect(!WindowIndex.shouldAcceptTitleSnapshot(
        currentReceivedAt: 200,
        currentSequence: 10,
        candidateReceivedAt: 199,
        candidateSequence: 99
    ))
    #expect(!WindowIndex.shouldAcceptTitleSnapshot(
        currentReceivedAt: 200,
        currentSequence: 10,
        candidateReceivedAt: 200,
        candidateSequence: 9
    ))
    #expect(WindowIndex.shouldAcceptTitleSnapshot(
        currentReceivedAt: 200,
        currentSequence: 10,
        candidateReceivedAt: 200,
        candidateSequence: 11
    ))
    #expect(WindowIndex.shouldAcceptTitleSnapshot(
        currentReceivedAt: 200,
        currentSequence: 10,
        candidateReceivedAt: 201,
        candidateSequence: 1
    ))
}

@Test func concurrentTitleSnapshotProducersReceiveUniqueSequences() async {
    var sequences: [UInt64] = []
    await withTaskGroup(of: UInt64.self) { group in
        for _ in 0..<512 {
            group.addTask { WindowIndex.nextTitleSnapshotSequence() }
        }
        for await sequence in group { sequences.append(sequence) }
    }
    #expect(Set(sequences).count == 512)
}

@Test func accessibilityValuesRejectUnexpectedCoreFoundationTypes() {
    var point = CGPoint(x: 10, y: 20)
    let value = AXValueCreate(.cgPoint, &point)!
    let element = AXUIElementCreateSystemWide()
    let wrong = "not an accessibility value" as CFString

    #expect(AXCore.checkedValue(value) != nil)
    #expect(AXCore.checkedValue(wrong) == nil)
    #expect(AXCore.checkedElement(element) != nil)
    #expect(AXCore.checkedElement(wrong) == nil)
}
