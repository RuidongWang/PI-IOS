import Foundation
import QuartzCore
import UIKit
import PIiOSCore

/// Records display callback gaps and main-queue response delays separately.
/// Only active while logging is enabled and the scene is active.
@MainActor
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()
    static let thresholdMilliseconds: Double = 150

    private var displayLink: CADisplayLink?
    private var tracker = PILogFrameIntervalTracker(thresholdMilliseconds: thresholdMilliseconds)
    private var isEnabled = false
    private var isSceneActive = true
    private let responsiveness = UIResponsivenessProbe()
    private let watchdogQueue = DispatchQueue(label: "dev.piios.ui-responsiveness", qos: .utility)
    private var watchdog: DispatchSourceTimer?

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        reconcile()
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        reconcile()
    }

    private func reconcile() {
        if isEnabled && isSceneActive { start() } else { stop() }
    }

    private func start() {
        guard displayLink == nil else { return }
        tracker.reset()
        responsiveness.start(now: ProcessInfo.processInfo.systemUptime)
        let probe = responsiveness
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler {
            switch probe.tick(now: ProcessInfo.processInfo.systemUptime) {
            case .dispatch(let id):
                DispatchQueue.main.async {
                    if let latency = probe.acknowledge(id, now: ProcessInfo.processInfo.systemUptime), latency >= 250 {
                        PILog.warn("UI", "main response recovered latencyMs=\(Int(latency.rounded()))")
                    }
                }
            case .delayed(let milliseconds):
                PILog.warn("UI", "main response delayed pendingMs=\(Int(milliseconds.rounded()))")
            case .idle:
                break
            }
        }
        watchdog = timer
        timer.resume()
        let link = CADisplayLink(target: self, selector: #selector(handleFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        responsiveness.stop()
        watchdog?.setEventHandler {}
        watchdog?.cancel()
        watchdog = nil
        displayLink?.invalidate()
        displayLink = nil
        tracker.reset()
    }

    @objc private func handleFrame() {
        guard let gap = tracker.ingest(timestamp: CACurrentMediaTime()) else { return }
        let response = responsiveness.snapshot(now: ProcessInfo.processInfo.systemUptime)
        PILog.warn(
            "UI",
            "display frame gap frameGapMs=\(Int(gap.rounded()))"
                + " pendingMainMs=\(Int(response.pendingMilliseconds.rounded()))"
                + " sinceMainResponseMs=\(Int(response.sinceResponseMilliseconds.rounded()))"
        )
    }
}
