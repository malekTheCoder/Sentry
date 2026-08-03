import Foundation
import os

// MARK: - SentryFanDaemon — the privileged half of fan control
//
// This process runs as **root**, launched by launchd from
// `Sentry.app/Contents/Library/LaunchDaemons/dev.malekswilam.sentry
// .fandaemon.plist` after the user explicitly installs it from
// Settings ▸ Fans. It exists because writing an SMC fan key requires uid 0
// on Apple Silicon and Sentry itself runs unprivileged
// (`docs/fan-control-spike.md`).
//
// **Read `SentryKit/FanDaemon/FanDaemonContract.swift` first.** It carries
// the threat model, the "what is unverified" list, and the reasoning behind
// the deliberately tiny command vocabulary.
//
// What this file is responsible for, and nothing else:
//
//   1. Probe the SMC for fan count and per-fan limits, *before* the
//      listener is resumed, so no request can be served against unknown
//      bounds.
//   2. Install signal handlers that hand every held fan back to the
//      firmware. Safety requirement 4.
//   3. Publish the Mach service and hand connections to the peer gate.
//   4. Tick once a second so heartbeat expiry and idle exit are real rather
//      than aspirational.
//
// **Why dispatch sources rather than `signal(2)` handlers.** A classic
// `sa_handler` may only call async-signal-safe functions — no allocation,
// no `Logger`, no IOKit. The revert path needs all three. `DispatchSource
// .makeSignalSource` delivers the notification as ordinary code on an
// ordinary queue, after `signal(sig, SIG_IGN)` disarms the default
// disposition, which is what makes a real revert-on-terminate possible at
// all. `atexit` is registered as well, for the paths that unwind normally
// rather than via a signal.
//
// **What still cannot be protected: `SIGKILL`.** No handler of any kind
// runs. See `FanDaemonFailSafe`'s doc comment for what bounds the damage
// (the SMC's own floor, and the override not surviving a power cycle) and
// what does not.

let log = Logger(subsystem: FanDaemonNaming.label, category: "main")

let writer = SMCFanWriter()
guard writer.isOpen else {
    // Not a crash and not a silent exit: a daemon that cannot open the SMC
    // user client can do nothing useful, and staying alive as a root
    // process that can only refuse requests is strictly worse than not
    // being there. The app reports this as the helper being unreachable —
    // which is true — rather than as fan control being unsupported, which
    // would be a claim about the hardware this process failed to examine.
    log.fault("Could not open the AppleSMC user client; exiting rather than lingering as a root process that can do nothing.")
    exit(EXIT_FAILURE)
}

let service = FanDaemonService(
    writer: writer,
    evaluator: SecurityFrameworkPeerEvaluator()
)

// Step 1: bounds before service. See `FanDaemonService.probeHardware`.
service.probeHardware()

// Step 2: fail-safe on every exit path we can actually observe.
//
// `atexit` covers a normal unwind. It runs on the exiting thread with the
// process still fully alive, so the IOKit calls inside are legal.
atexit {
    service.revertEverythingSynchronously(signal: nil)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    // Disarm the default disposition first — otherwise the process dies
    // before the dispatch source ever runs, and the handler below is
    // decoration.
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        service.revertEverythingSynchronously(signal: sig)
        // `exit` runs the `atexit` handler above a second time. That is
        // intentional and harmless: reverting a fan already handed back
        // writes `F{i}Md = 0` over a `0`, and belt-and-braces on the one
        // path that matters most is worth an idempotent duplicate write.
        exit(EXIT_SUCCESS)
    }
    source.resume()
    signalSources.append(source)
}

// Step 3: publish. `NSXPCListener(machServiceName:)` is the LaunchDaemon
// form — launchd owns the port and hands it over, so this must match the
// `MachServices` key in the plist exactly, which is why both come from
// `FanDaemonNaming`.
let listener = NSXPCListener(machServiceName: FanDaemonNaming.machService)
listener.delegate = service
service.onExitRequested = {
    // Reached only from `.idleWithNoClient` — the leaked-daemon path. The
    // reverts have already been issued by `performRevert` at this point.
    log.notice("Exiting after the idle window with no client.")
    exit(EXIT_SUCCESS)
}
listener.resume()

// Step 4: the clock. One second is far finer than either window it drives
// (15 s heartbeat timeout, 60 s idle exit) and costs nothing measurable in
// a process that is otherwise entirely idle — and the alternative, arming
// and re-arming a timer per window, is the kind of bookkeeping that fails
// quietly in exactly the case the window exists for.
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 1, repeating: 1)
ticker.setEventHandler {
    service.tick()
}
ticker.resume()

log.notice("SentryFanDaemon started; listening on \(FanDaemonNaming.machService, privacy: .public).")

dispatchMain()
