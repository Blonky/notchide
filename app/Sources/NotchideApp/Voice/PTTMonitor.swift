import ApplicationServices
import CoreGraphics
import Foundation

/// Push-to-talk summon: detects a HOLD of Control+Option (no other primary key)
/// via a `CGEventTap`, discriminated from the existing ⌘⌥N tap-summon hotkey.
///
///   • press (Control+Option engaged)     → `onPress`   (start listening)
///   • release (either modifier lifted)   → `onRelease` (finalize)
///   • a real key pressed while held      → `onCancel`  (it was a shortcut)
///
/// A `CGEventTap` requires the app to be trusted for Accessibility. If it is not,
/// `start()` logs and becomes an inert no-op — the rest of the app keeps working,
/// and the build/run never depends on the grant. The tap is `.listenOnly`, so it
/// only observes the modifier chord and never swallows the user's keystrokes.
@MainActor
public final class PTTMonitor {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Whether the Control+Option chord is currently held.
    private var isEngaged = false

    public init() {}

    public func start() {
        guard AXIsProcessTrusted() else {
            NSLog("notchide: PTT disabled — Accessibility trust not granted (CGEventTap unavailable)")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: pttEventTapCallback,
            userInfo: refcon
        ) else {
            NSLog("notchide: PTT disabled — failed to create CGEventTap")
            return
        }
        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isEngaged = false
    }

    /// Called from the event-tap callback (on the main run loop). Never modifies
    /// the passing event — the tap is listen-only. Takes the already-extracted
    /// `CGEventFlags` (Sendable) rather than the non-Sendable `CGEvent`.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .flagsChanged:
            let match = flags.contains(.maskControl)
                && flags.contains(.maskAlternate)
                && !flags.contains(.maskCommand)
                && !flags.contains(.maskShift)
            if match, !isEngaged {
                isEngaged = true
                onPress?()
            } else if !match, isEngaged {
                isEngaged = false
                onRelease?()
            }

        case .keyDown:
            // A real key while the chord is held means the user is typing a
            // shortcut, not push-to-talking — abandon the session.
            if isEngaged {
                isEngaged = false
                onCancel?()
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system may disable a long-idle tap; re-arm it.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        default:
            break
        }
    }
}

/// The C-ABI event-tap trampoline. Runs on the main run loop (the source is added
/// to `CFRunLoopGetMain`), so it can safely hop onto the main actor synchronously.
private func pttEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<PTTMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        // Extract the Sendable flags on this (main-run-loop) thread; never send the
        // non-Sendable CGEvent across the actor hop.
        let flags = event.flags
        MainActor.assumeIsolated {
            monitor.handle(type: type, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}
