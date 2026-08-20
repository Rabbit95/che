import Foundation

/// A dedicated thread that owns a persistent, live `CFRunLoop` for driving
/// ImageCaptureCore (`ICDeviceBrowser` / `ICCameraDevice`).
///
/// # Why this exists (`.j`)
///
/// ImageCaptureCore is a classic RunLoop-based Cocoa API: an `ICDevice`
/// services its USB/PTP I/O and delivers *all* of its delegate callbacks on
/// the thread whose `CFRunLoop` was spinning when the owning `ICDeviceBrowser`
/// was created and `start()`-ed — and **only while that runloop keeps
/// spinning**. Every build up to `.i` created the browser on Flutter's main
/// thread and drove every `requestOpenSession` / `requestSendPTPCommand` from
/// `DispatchQueue.main`. That main runloop is shared with UIKit rendering,
/// the Flutter engine's platform-channel traffic, and every other plugin.
///
/// The reverse-engineering of Cascable Studio 7.2.2 showed its `ICCPTPTransport`
/// runs the entire ICA stack on a private serial thread with its own runloop
/// (see the `cascable-connection-method` memo). At the ICA *API* level Cascable
/// is byte-for-byte identical to `.i` (same empty-dict options-open, same
/// `requestSendPTPCommand` passthrough) yet enumerates the SAME SD card ~16×
/// faster. The leading remaining hypothesis for that gap is that ICA's
/// fine-grained first-command servicing is starved on our busy main runloop.
/// This class isolates ICA onto its own thread so its I/O sources are serviced
/// promptly and deterministically.
///
/// # Contract
///
/// - The thread is created and its runloop is confirmed live before `init`
///   returns, so `perform`/`performSync` are safe immediately.
/// - The runloop is kept from exiting by a permanently-installed `NSMachPort`
///   input source; it blocks in `RunLoop.run` between events, so scheduled
///   blocks — and ICA's own callbacks — fire with no busy-spin.
/// - `perform` marshals a block onto the runloop asynchronously (wake-up
///   included). `performSync` blocks the caller until the block finishes, and
///   short-circuits to an inline call if invoked from the ICA thread itself
///   (so it can never deadlock on re-entry).
final class IccIcaThread {
  private var thread: Thread!
  // Set once on the ICA thread before `readySem` is signalled; only read after
  // callers have observed that signal (via init's `wait()`), so publication is
  // safe without further synchronisation. Never mutated again.
  private var cfRunLoop: CFRunLoop?
  private let readySem = DispatchSemaphore(value: 0)
  // Best-effort stop flag. Written by `stop()` on an arbitrary thread, read on
  // the ICA thread. A benign `Bool` race — worst case is one extra runloop
  // pass. This thread lives for the whole app session, so `stop()` effectively
  // never runs in practice.
  private var isStopped = false

  init(name: String) {
    thread = Thread { [weak self] in
      self?.runLoopMain()
    }
    thread.name = name
    thread.qualityOfService = .userInitiated
    thread.start()
    // Block the constructing thread until the runloop is captured and kept
    // alive, so the first `perform`/`performSync` can never miss it.
    readySem.wait()
  }

  private func runLoopMain() {
    cfRunLoop = CFRunLoopGetCurrent()
    // A no-op Mach port keeps `RunLoop.run` from returning immediately when no
    // other sources are attached yet (ICA installs its own sources on start()).
    let keepAlive = NSMachPort()
    RunLoop.current.add(keepAlive, forMode: .common)
    readySem.signal()
    while !isStopped {
      // Blocks until an input source fires (a `perform` block, or one of ICA's
      // USB/PTP sources), services it, then re-enters. `distantFuture` means we
      // never wake spuriously.
      RunLoop.current.run(mode: .default, before: .distantFuture)
    }
  }

  /// Schedule `block` to run on the ICA thread's runloop, asynchronously.
  func perform(_ block: @escaping () -> Void) {
    guard let runLoop = cfRunLoop else {
      // Unreachable after init's semaphore wait; retry defensively rather than
      // silently dropping the block.
      DispatchQueue.global().async { [weak self] in self?.perform(block) }
      return
    }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  /// Run `block` on the ICA thread and wait for it to finish. Runs inline when
  /// already on the ICA thread to avoid a self-deadlock.
  func performSync(_ block: @escaping () -> Void) {
    if Thread.current === thread {
      block()
      return
    }
    let done = DispatchSemaphore(value: 0)
    perform {
      block()
      done.signal()
    }
    done.wait()
  }

  /// Signal the runloop to exit. Best-effort; primarily for teardown in tests.
  func stop() {
    isStopped = true
    if let runLoop = cfRunLoop { CFRunLoopWakeUp(runLoop) }
  }
}
