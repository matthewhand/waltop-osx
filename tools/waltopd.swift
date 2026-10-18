// waltopd.swift
//
// Userspace pressure shim for the WALTOP Slim Tablet 12.1" (USB 172f:0031) on macOS.
//
// Build:  swiftc -O -o waltopd waltopd.swift
// Test:   ./waltopd --selftest
//
// ----------------------------------------------------------------------------
// THE PROBLEM
//
// This tablet's firmware mislabels its tip-pressure field in the HID report
// descriptor: it declares Digitizer usage 0x30 ("X") where it should declare
// 0x33 ("Pressure"). macOS honours the declared usage, so the pen's position and
// buttons arrive normally but pressure is reported to every application as
// exactly 0.0. The real 0-1023 value IS present in the USB reports; it is
// discarded during HID parsing.
//
// A kernel extension could rewrite the descriptor, but that needs SIP disabled
// and reduced security on the host. This shim does the same job in userspace:
//
//   1. seize the device so the OS stops mis-reporting it,
//   2. read the raw pressure element ourselves,
//   3. republish the data as correctly-formed CoreGraphics tablet events.
//
// ----------------------------------------------------------------------------
// THE ONE NON-OBVIOUS PART
//
// Qt (and therefore Krita) registers a tablet device ONLY when it receives a
// proximity event whose device id matches the point events that follow, with the
// "enter" flag set. Get any of that wrong and Qt silently DISCARDS every tablet
// event thereafter -- the pen appears completely dead, with no click of any
// sort. See makeProximity() below for the exact fields.
//
// Applications using Qt additionally need the tablet event's own button bits to
// be trusted, via:
//     QT_MAC_TABLET_IGNORE_BUTTON_MAPPING=1
// Otherwise Qt decides "pen down" from its internal mouse state, which a
// synthetic tablet event never updates.
//
// ----------------------------------------------------------------------------
// USAGE
//
//   ./waltopd --list            list HID devices with vendor/product IDs, then exit
//   ./waltopd --selftest        run the built-in event-encoding tests, then exit
//   ./waltopd                   run the shim (seizes the tablet), logs to ./waltopd.log
//   ./waltopd --no-seize        debug: do NOT seize (broken events interleave)
//   ./waltopd --no-csv          skip the per-sample CSV
//   ./waltopd --log-file PATH   write the log somewhere else
//   ./waltopd --debug           log every raw HID event
//
//   Stop with Ctrl-C or `pkill -x waltopd`.
//
// Suggested launch for Krita (see kritadraw.sh):
//   pkill -x krita; ./waltopd &
//   launchctl setenv QT_MAC_TABLET_IGNORE_BUTTON_MAPPING 1
//   open -a Krita
//
// OUTPUT
//   waltopd.log          log incl. per-stroke summaries and 5s stats
//   waltopd-samples.csv  timestamped x,y,pressure samples for analysis

import Cocoa
import IOKit.hid
import CoreGraphics

// ---------------------------------------------------------------- constants

let VENDOR  = 0x172F
let PRODUCT = 0x0031

let UP_DIGITIZER: UInt32 = 0x0D
let UP_DESKTOP:   UInt32 = 0x01

// HID usages we bind, with the names the spec gives them.
let USAGE_X: UInt32 = 0x30
let USAGE_Y: UInt32 = 0x31
let USAGE_IN_RANGE: UInt32 = 0x32
let USAGE_PRESSURE: UInt32 = 0x33
let USAGE_TIP_SWITCH: UInt32 = 0x42
let USAGE_BARREL_SWITCH: UInt32 = 0x44
let USAGE_SECONDARY_BARREL: UInt32 = 0x45

// Tablet active area and pressure resolution as declared by the device.
let TABLET_MAX_X: Double = 10000
let TABLET_MAX_Y: Double = 6250
let TABLET_MAX_PRESSURE: Double = 1023

// CoreGraphics event fields. The proximity fields are undocumented in the public
// CGEventField enum, so they are spelled out here with their real meanings.
enum Field {
    static let proximityVendorID         = CGEventField(rawValue: 28)! // kCGTabletProximityEventVendorID
    static let proximityTabletID         = CGEventField(rawValue: 29)! // kCGTabletProximityEventTabletID
    static let proximityDeviceID         = CGEventField(rawValue: 31)! // kCGTabletProximityEventDeviceID
    static let proximitySystemTabletID   = CGEventField(rawValue: 32)! // kCGTabletProximityEventSystemTabletID
    static let proximityVendorPointerType = CGEventField(rawValue: 33)! // kCGTabletProximityEventVendorPointerType
    static let proximityPointerType      = CGEventField(rawValue: 37)! // kCGTabletProximityEventPointerType (1 = Pen)
    static let proximityEnter            = CGEventField(rawValue: 38)! // kCGTabletProximityEventEnterProximity (1 = enters)
    static let eventSourceUserData       = CGEventField(rawValue: 42)! // kCGEventSourceUserData
}

// The tablet device id we advertise. It only has to be consistent between the
// proximity event and the point events; Qt keys its registry on it.
let DEVICE_ID: Int64 = 1

// ------------------------------------------------------------------- args

let args = CommandLine.arguments

func usage() {
    FileHandle.standardError.write("""
    waltopd - userspace pressure shim for the WALTOP Slim Tablet 12.1" (172f:0031)

      --list            list HID devices with vendor/product IDs, then exit
      --selftest        run the built-in event-encoding tests, then exit
      --no-seize        do not seize the device (debug; events will interleave)
      --no-csv          do not write waltopd-samples.csv
      --log-file PATH   write the log to PATH (default ./waltopd.log)
      --debug           log every raw HID event
      --help            show this message

    """.data(using: .utf8)!)
}

if args.contains("--help") || args.contains("-h") { usage(); exit(0) }

let seize   = !args.contains("--no-seize")
let wantCSV = !args.contains("--no-csv")

// --------------------------------------------------------------- singleton
// All mutable state lives in a singleton: the HID value callback is a C
// function pointer, which cannot capture context or reference file-scope
// variables, but it can reach a lazily-initialised static.

final class Shim {
    static let shared = Shim()

    var cookieX: IOHIDElementCookie = 0
    var cookieY: IOHIDElementCookie = 0
    var cookiePressure: IOHIDElementCookie = 0
    var cookieTip: IOHIDElementCookie = 0
    var cookieBarrel: IOHIDElementCookie = 0
    var cookieBarrel2: IOHIDElementCookie = 0
    var cookieInRange: IOHIDElementCookie = 0

    var curX = 0.0
    var curY = 0.0
    var curPressure = 0.0
    var curTip = false
    var curBarrel = false
    var curBarrel2 = false
    var curInRange = false
    var proximityPosted = false

    var eventCount = 0
    var postedCount = 0
    var lastHidEvent = Date.distantPast
    var lastEmit = Date.distantPast
    var lastCsvSample = Date.distantPast

    var strokeActive = false
    var strokeStart = Date()
    var strokePeak = 0.0
    var strokeSamples = 0
    var strokeCount = 0
    var globalPeak = 0.0
    var modeName = "unknown"
    var debug = false
    var logHandle: FileHandle?
    var csvHandle: FileHandle?
    let iso = ISO8601DateFormatter()
    let displayBounds = CGDisplayBounds(CGMainDisplayID())

    func writeLog(_ s: String) {
        let line = "\(iso.string(from: Date()))  \(s)\n"
        logHandle?.write(line.data(using: .utf8)!)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    func writeCsv(_ s: String) { csvHandle?.write((s + "\n").data(using: .utf8)!) }

    func endStroke(_ reason: String) {
        guard strokeActive else { return }
        let dur = Date().timeIntervalSince(strokeStart)
        let norm = strokePeak / TABLET_MAX_PRESSURE
        writeLog(String(format: "[stroke %d] END (%@) dur=%.2fs samples=%d peakRaw=%.0f peakNorm=%.4f (%.1f%% of full scale)",
                        strokeCount, reason, dur, strokeSamples, strokePeak, norm, norm * 100))
        strokeActive = false
    }
}

Shim.shared.debug = args.contains("--debug")

func logline(_ s: String) { Shim.shared.writeLog(s) }
func csvRow(_ s: String) { Shim.shared.writeCsv(s) }

// ------------------------------------------------------------ event builders

func displayLocation() -> CGPoint {
    let s = Shim.shared
    let nx = min(max(s.curX / TABLET_MAX_X, 0), 1)
    let ny = min(max(s.curY / TABLET_MAX_Y, 0), 1)
    return CGPoint(x: s.displayBounds.minX + nx * s.displayBounds.width,
                   y: s.displayBounds.minY + ny * s.displayBounds.height)
}

// Build a tablet proximity ("entered/left the tablet") event.
//
// Two traps, both of which make Qt silently ignore everything that follows:
//   * the proximity device id is field 31, NOT the point events' field 24; and
//   * field 38 must be non-zero for an "enter". Zero means "leave", which makes
//     Qt DEREGISTER the device rather than register it.
func makeProximity(_ inRange: Bool) -> CGEvent {
    let e = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
    e.type = .tabletProximity
    e.location = displayLocation()

    e.setIntegerValueField(Field.proximityDeviceID, value: DEVICE_ID)
    e.setIntegerValueField(Field.proximityEnter, value: inRange ? 1 : 0)
    e.setIntegerValueField(Field.proximityPointerType, value: 1)       // Pen
    e.setIntegerValueField(Field.proximityVendorPointerType, value: 1) // Pen
    e.setIntegerValueField(Field.proximitySystemTabletID, value: 1)
    e.setIntegerValueField(Field.proximityVendorID, value: Int64(VENDOR))
    e.setIntegerValueField(Field.proximityTabletID, value: Int64(PRODUCT))

    // A proximity event carries no pressure. Anything non-zero here makes apps
    // believe the pen is already pressed while merely hovering.
    e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
    return e
}

// Build a tablet point event carrying position, pressure and the tip button.
func makeEvent(_ pressure01: Double) -> CGEvent {
    let s = Shim.shared
    let e = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
    e.type = .tabletPointer
    e.location = displayLocation()

    e.setDoubleValueField(.tabletEventPointPressure, value: min(max(pressure01, 0), 1))
    e.setDoubleValueField(.tabletEventTiltX, value: 0)
    e.setDoubleValueField(.tabletEventTiltY, value: 0)
    e.setDoubleValueField(.tabletEventRotation, value: 0)
    e.setDoubleValueField(.tabletEventTangentialPressure, value: 0)
    e.setIntegerValueField(.tabletEventDeviceID, value: DEVICE_ID)
    e.setIntegerValueField(Field.eventSourceUserData, value: 1)

    // AppKit preserves button state for tablet events only in this field.
    // Bit 0 is the tip, bit 1 is the primary barrel switch, and bit 2 is the
    // secondary barrel switch. Qt uses these when
    // QT_MAC_TABLET_IGNORE_BUTTON_MAPPING=1 is set.
    var buttonBits: Int64 = s.curTip ? 1 : 0
    if s.curBarrel { buttonBits |= 2 }
    if s.curBarrel2 { buttonBits |= 4 }
    e.setIntegerValueField(.tabletEventPointButtons, value: buttonBits)
    e.setIntegerValueField(.mouseEventClickState, value: s.curTip ? 1 : 0)
    return e
}

// ---------------------------------------------------------------- selftest
// A real regression test for the bug that cost the most time. If someone
// "simplifies" makeProximity() back to its broken form, this fails.

func runSelftest() -> Bool {
    var allPassed = true

    func report(_ name: String, _ ok: Bool, _ expected: String, _ got: String) {
        allPassed = allPassed && ok
        print("\(ok ? "ok  " : "FAIL") \(name)" + (ok ? "" : "   (expected \(expected), got \(got))"))
    }
    func checkI(_ name: String, _ got: Int64, _ expected: Int64) {
        report(name, got == expected, "\(expected)", "\(got)")
    }
    func checkD(_ name: String, _ got: Double, _ expected: Double) {
        report(name, abs(got - expected) < 0.0001, "\(expected)", "\(got)")
    }

    let enter = makeProximity(true)
    checkI("proximity enter sets EnterProximity=1", enter.getIntegerValueField(Field.proximityEnter), 1)
    checkI("proximity enter sets DeviceID (field 31, not 24)", enter.getIntegerValueField(Field.proximityDeviceID), DEVICE_ID)
    checkI("proximity enter sets pointer type = Pen", enter.getIntegerValueField(Field.proximityPointerType), 1)
    checkD("proximity carries no pressure", enter.getDoubleValueField(.tabletEventPointPressure), 0.0)

    let leave = makeProximity(false)
    checkI("proximity leave sets EnterProximity=0", leave.getIntegerValueField(Field.proximityEnter), 0)

    Shim.shared.curTip = true
    let down = makeEvent(0.5)
    checkD("point event pressure round-trips", down.getDoubleValueField(.tabletEventPointPressure), 0.5)
    checkI("point event sets tip button bit when tip down", down.getIntegerValueField(.tabletEventPointButtons), 1)
    checkI("point event device id matches proximity", down.getIntegerValueField(.tabletEventDeviceID), DEVICE_ID)

    Shim.shared.curTip = false
    Shim.shared.curBarrel = true
    let barrel1 = makeEvent(0.0)
    checkI("point event sets primary barrel button bit", barrel1.getIntegerValueField(.tabletEventPointButtons), 2)

    Shim.shared.curBarrel2 = true
    let barrels = makeEvent(0.0)
    checkI("point event sets both barrel button bits", barrels.getIntegerValueField(.tabletEventPointButtons), 6)

    Shim.shared.curBarrel = false
    Shim.shared.curBarrel2 = false
    let up = makeEvent(0.0)
    checkI("point event clears button bits when all buttons up", up.getIntegerValueField(.tabletEventPointButtons), 0)

    print(allPassed ? "selftest: PASS" : "selftest: FAIL")
    return allPassed
}

// ------------------------------------------------------------------- --list
// Enumerate HID devices so a user can find their tablet's vendor/product IDs.

func propString(_ d: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "?"
}
func propInt(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? -1
}

func listDevices() {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)
    // Opening is not required to enumerate, and it fails with
    // kIOReturnExclusiveAccess when something (e.g. a running waltopd) already
    // holds a device. Enumerate anyway.
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        print("note: HID manager open returned 0x\(String(format: "%08x", UInt32(bitPattern: r))); enumerating anyway.")
        print("      (if a device is missing below, stop any running waltopd: pkill -x waltopd)\n")
    }
    guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else {
        print("no HID devices returned")
        exit(0)
    }

    let rows = set.map { d -> (Int, Int, String, String) in
        (propInt(d, kIOHIDVendorIDKey), propInt(d, kIOHIDProductIDKey),
         propString(d, kIOHIDProductKey), propString(d, kIOHIDManufacturerKey))
    }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }

    print("VID      PID     PRODUCT                          MANUFACTURER")
    for (vid, pid, product, mfr) in rows {
        let tag = (vid == VENDOR && pid == PRODUCT) ? "   <== this project's tablet" : ""
        let v = vid >= 0 ? String(format: "0x%04x", vid) : "   -  "
        let p = pid >= 0 ? String(format: "0x%04x", pid) : "   -  "
        print("\(v)   \(p)  \(product.padding(toLength: 32, withPad: " ", startingAt: 0)) \(mfr)\(tag)")
    }
    print("\nlook for vendor 0x172f. If your tablet is a different WALTOP model,")
    print("change VENDOR/PRODUCT at the top of waltopd.swift.")
}

if args.contains("--list") { listDevices(); exit(0) }
if args.contains("--selftest") { exit(runSelftest() ? 0 : 1) }

// ---------------------------------------------------------------- logging

var logPath = FileManager.default.currentDirectoryPath + "/waltopd.log"
if let i = args.firstIndex(of: "--log-file"), i + 1 < args.count { logPath = args[i + 1] }
let logDir = (logPath as NSString).deletingLastPathComponent
let csvPath = logDir + "/waltopd-samples.csv"

// Rotate the previous run so the log always describes the current session.
try? FileManager.default.removeItem(atPath: logPath + ".1")
try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".1")
try? FileManager.default.removeItem(atPath: csvPath)

// FileHandle(forWritingAtPath:) does NOT create the file, and we just rotated
// the previous log away, so make sure both files exist first.
FileManager.default.createFile(atPath: logPath, contents: Data())
if wantCSV { FileManager.default.createFile(atPath: csvPath, contents: Data()) }

guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
    FileHandle.standardError.write("cannot open \(logPath) for writing\n".data(using: .utf8)!)
    exit(1)
}
let csvHandle: FileHandle? = wantCSV ? FileHandle(forWritingAtPath: csvPath) : nil
csvHandle?.write("timestamp,mode,x,y,pressure_raw,pressure_norm,tip\n".data(using: .utf8)!)
Shim.shared.logHandle = logHandle
Shim.shared.csvHandle = csvHandle

// ---------------------------------------------------------- single instance
// A previous run may still hold the device under seize, which makes this run's
// seize fail with a bare IOKit code. Detect that up front and say so plainly.
let lockPath = logDir + "/waltopd.lock"
if let existing = try? String(contentsOfFile: lockPath, encoding: .utf8),
   let pid = Int(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
   pid != Int(getpid()), kill(pid_t(pid), 0) == 0 {
    logline("[err] another waltopd is already running (pid \(pid)) and is holding the tablet.\n[err] stop it first:  pkill -x waltopd")
    exit(1)
}
try? String(getpid()).write(toFile: lockPath, atomically: true, encoding: .utf8)

// ------------------------------------------------------------- HID binding

func parentIsDigitizer(_ el: IOHIDElement) -> Bool {
    guard let p = IOHIDElementGetParent(el) else { return false }
    return IOHIDElementGetUsagePage(p) == UP_DIGITIZER
}

func bindElements(_ device: IOHIDDevice) {
    let s = Shim.shared
    guard let els = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return }

    for el in els {
        let page = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let cookie = IOHIDElementGetCookie(el)

        // X/Y live on the Generic Desktop page, so there is deliberately no page
        // guard here. The device also declares a mouse collection with its own
        // X/Y, which we must not pick up.
        if page == UP_DESKTOP && usage == USAGE_X && parentIsDigitizer(el) { s.cookieX = cookie }
        else if page == UP_DESKTOP && usage == USAGE_Y && parentIsDigitizer(el) { s.cookieY = cookie }
        // This firmware mislabels pressure as Digitizer 0x30 ("X"). USAGE_PRESSURE
        // is the correct label, kept for properly-behaved units.
        else if page == UP_DIGITIZER && (usage == USAGE_PRESSURE || usage == USAGE_X) { s.cookiePressure = cookie }
        else if page == UP_DIGITIZER && usage == USAGE_TIP_SWITCH { s.cookieTip = cookie }
        else if page == UP_DIGITIZER && usage == USAGE_BARREL_SWITCH { s.cookieBarrel = cookie }
        else if page == UP_DIGITIZER && usage == USAGE_SECONDARY_BARREL { s.cookieBarrel2 = cookie }
        else if page == UP_DIGITIZER && usage == USAGE_IN_RANGE { s.cookieInRange = cookie }
    }
    logline("[hid] bound x=\(s.cookieX) y=\(s.cookieY) pressure=\(s.cookiePressure) tip=\(s.cookieTip) barrel=\(s.cookieBarrel) barrel2=\(s.cookieBarrel2) inRange=\(s.cookieInRange)")
    if s.cookiePressure == 0 { logline("[warn] no pressure element bound — cannot republish pressure") }
}

let valueCallback: IOHIDValueCallback = { _, _, _, value in
    let s = Shim.shared
    let el = IOHIDValueGetElement(value)
    let c = IOHIDElementGetCookie(el)
    let v = Double(IOHIDValueGetIntegerValue(value))

    if c == s.cookieX { s.curX = v }
    else if c == s.cookieY { s.curY = v }
    else if c == s.cookiePressure { s.curPressure = v }
    else if c == s.cookieTip { s.curTip = v != 0 }
    else if c == s.cookieBarrel { s.curBarrel = v != 0 }
    else if c == s.cookieBarrel2 { s.curBarrel2 = v != 0 }
    else if c == s.cookieInRange { s.curInRange = v != 0 }

    s.eventCount += 1
    s.lastHidEvent = Date()
    if s.curPressure > s.globalPeak { s.globalPeak = s.curPressure }

    if s.curTip && !s.strokeActive {
        s.strokeActive = true
        s.strokeCount += 1
        s.strokeStart = Date()
        s.strokePeak = 0
        s.strokeSamples = 0
        logline("[stroke \(s.strokeCount)] START x=\(Int(s.curX)) y=\(Int(s.curY))")
    } else if !s.curTip && s.strokeActive {
        s.endStroke("tip up")
    }
    if s.strokeActive {
        s.strokeSamples += 1
        if s.curPressure > s.strokePeak { s.strokePeak = s.curPressure }
    }

    if s.debug {
        logline(String(format: "[raw] x=%.0f y=%.0f p=%.0f tip=%d", s.curX, s.curY, s.curPressure, s.curTip ? 1 : 0))
    }
}

let matchingCallback: IOHIDDeviceCallback = { _, r, _, d in
    guard r == kIOReturnSuccess else { return }
    bindElements(d)
}

// ------------------------------------------------------------------- pump

func pump() {
    let s = Shim.shared

    // Pen gone: withdraw proximity so the app exits tablet mode cleanly.
    if s.eventCount > 0, Date().timeIntervalSince(s.lastHidEvent) >= 2.0 {
        if s.proximityPosted {
            makeProximity(false).post(tap: .cghidEventTap)
            s.proximityPosted = false
            logline("[evt] posted tabletProximity(out-of-range)")
        }
        return
    }
    guard s.eventCount > 0 else { return }

    let now = Date()
    guard now.timeIntervalSince(s.lastEmit) >= 1.0 / 120.0 else { return }
    s.lastEmit = now

    // Qt apps only treat events as tablet input after a proximity "enter".
    if !s.proximityPosted {
        makeProximity(true).post(tap: .cghidEventTap)
        s.proximityPosted = true
        logline("[evt] posted tabletProximity(in-range)")
    }

    let norm = s.curPressure / TABLET_MAX_PRESSURE
    makeEvent(norm).post(tap: .cghidEventTap)
    s.postedCount += 1

    if now.timeIntervalSince(s.lastCsvSample) >= 1.0 / 60.0 {
        s.lastCsvSample = now
        csvRow(String(format: "%.3f,%@,%.0f,%.0f,%.0f,%.6f,%d",
                      now.timeIntervalSince1970, s.modeName, s.curX, s.curY, s.curPressure, norm, s.curTip ? 1 : 0))
    }
}

// ----------------------------------------------------------------- startup

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching = [kIOHIDVendorIDKey as String: NSNumber(value: VENDOR),
                kIOHIDProductIDKey as String: NSNumber(value: PRODUCT)] as CFDictionary
IOHIDManagerSetDeviceMatching(manager, matching)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, nil)
IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

let openResult = IOHIDManagerOpen(manager, seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone))

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
    logline("[err] tablet \(String(format: "0x%04x:0x%04x", VENDOR, PRODUCT)) not found.")
    logline("[err] plug it in and retry, or run `./waltopd --list` to see what is attached.")
    exit(1)
}
for d in devices { bindElements(d) }

if openResult != kIOReturnSuccess {
    logline("[err] open failed (\(openResult)). Another app may hold the tablet — quit it (pkill -x krita).")
    exit(1)
}
Shim.shared.modeName = seize ? "seize" : "noseize"

logline("[hid] open(\(Shim.shared.modeName)) = \(openResult)")
logline("[hid] display=\(Int(Shim.shared.displayBounds.width))x\(Int(Shim.shared.displayBounds.height))  tablet=\(Int(TABLET_MAX_X))x\(Int(TABLET_MAX_Y))  pressMax=\(Int(TABLET_MAX_PRESSURE))")
logline("[log] \(logPath)")
if wantCSV { logline("[log] \(csvPath)") }
logline(seize
         ? "[ready] SEIZED the tablet — the OS no longer sees it directly; this shim republishes it."
         : "[ready] NOT seized — broken device events will interleave with ours; pressure will be erratic.")
logline("[ready] For Krita: launch with QT_MAC_TABLET_IGNORE_BUTTON_MAPPING=1 (see kritadraw.sh).")
logline("")

RunLoop.current.add(Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in pump() }, forMode: .default)

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    let s = Shim.shared
    let idle = Date().timeIntervalSince(s.lastHidEvent)
    logline(String(format: "[stats] hid=%d posted=%d strokes=%d globalPeak=%.0f (%.2f%%)%@",
                   s.eventCount, s.postedCount, s.strokeCount, s.globalPeak,
                   (s.globalPeak / TABLET_MAX_PRESSURE) * 100,
                   (s.eventCount == 0 || idle > 5) ? "  ** PEN IDLE **" : ""))
}

signal(SIGINT) { _ in
    let s = Shim.shared
    s.endStroke("interrupted")
    logline("[exit] hid=\(s.eventCount) posted=\(s.postedCount) strokes=\(s.strokeCount) globalPeak=\(Int(s.globalPeak))")
    exit(0)
}

RunLoop.main.run()
