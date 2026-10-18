// ModeSweep.swift
//
// Tests all three input modes of the WALTOP tablet (172f:0031) and reports, per mode:
//   - whether the HID report descriptor changes
//   - whether macOS delivers usable pressure to applications
//
// INTERACTION MODEL
// There is no countdown for you to race. For each mode the tool switches the
// device, prints a prompt, and then BLOCKS until it sees your first pen event.
// Only then does it start its measurement window. If you are away for five
// minutes it waits five minutes. You stroke when you are ready.
//
// The descriptor is read BEFORE waiting, so you do not need to stroke for that part.
//
// Usage:
//   ./ModeSweep            measure all three modes, 20s window each
//   ./ModeSweep 30         use a 30s measurement window per mode
//
// QUIT Krita (and anything else holding the tablet) first.
//
// Build: swiftc -O -o ModeSweep ModeSweep.swift

import Foundation
import IOKit.hid
import CoreGraphics

let VENDOR = 0x172F
let PRODUCT = 0x0031
let MODE_REPORT_ID: UInt8 = 2
let MODE_COMMAND: UInt8 = 0x16

// Below this fraction of full scale, pressure is treated as noise rather than signal.
let PRESSURE_THRESHOLD = 0.01

private func logline(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// C callbacks cannot capture context.
private var maxPressure = 0.0
private var pointerEvents = 0
private var lastEventAt = Date.distantPast

private let modes: [(String, UInt8)] = [("default", 0x00), ("tablet", 0x01), ("ink", 0x02)]

let window = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 20) : 20

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching = [kIOHIDVendorIDKey as String: NSNumber(value: VENDOR),
                kIOHIDProductIDKey as String: NSNumber(value: PRODUCT)] as CFDictionary
IOHIDManagerSetDeviceMatching(manager, matching)
_ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty,
      let device = devices.first else {
    logline("[err] tablet not found — plug it in and retry"); exit(1)
}

logline("[hid] \(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?")  172f:0031")
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tabletPointer {
        pointerEvents += 1
        lastEventAt = Date()
        let p = event.getDoubleValueField(.tabletEventPointPressure)
        if p > maxPressure { maxPressure = p }
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: CGEventTapOptions(rawValue: 0)!,
                                 eventsOfInterest: CGEventMask(1 << UInt64(CGEventType.tabletPointer.rawValue)),
                                 callback: tapCallback, userInfo: nil) else {
    logline("[err] CGEventTap failed — grant Input Monitoring to your terminal"); exit(1)
}
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

/// Spin the runloop for `secs`, so HID/CGEvent callbacks actually fire.
@discardableResult
func pump(_ secs: Double) -> Bool {
    let deadline = Date().addingTimeInterval(secs)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return true
}

/// Block until the pen is actually used, so the user is never racing a countdown.
func waitForPen(timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if Date().timeIntervalSince(lastEventAt) < 0.5 { return true }
    }
    return false
}

func describePressureUsage() -> String {
    guard let rd = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
        return "descriptor unavailable"
    }
    let bytes = [UInt8](rd)
    var found: [String] = []
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x05, i + 1 < bytes.count, bytes[i + 1] == 0x0D {
            var j = i + 2
            while j < bytes.count, bytes[j] == 0xFE, j + 1 < bytes.count { j += Int(bytes[j + 1]) + 1 }
            if j < bytes.count, bytes[j] == 0x09, j + 1 < bytes.count {
                switch bytes[j + 1] {
                case 0x30: found.append("0x30(X)")
                case 0x33: found.append("0x33(Pressure)")
                case 0x34: found.append("0x34(XTilt)")
                case 0x35: found.append("0x35(YTilt)")
                default: break
                }
            }
        }
        i += 1
    }
    let uniq = Array(Set(found)).sorted()
    return uniq.isEmpty ? "no digitizer axis found" : uniq.joined(separator: ", ")
}

logline("")
logline("MODE SWEEP — \(modes.count) modes, \(Int(window))s measurement window each")
logline("The tool waits for your pen. Stroke whenever you are ready — there is no rush.")
logline("")

var results: [(name: String, events: Int, peak: Double, usage: String, ok: Bool)] = []

for (name, byte) in modes {
    var payload: [UInt8] = [MODE_COMMAND, byte]
    let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                                      CFIndex(MODE_REPORT_ID), &payload, CFIndex(payload.count))
    pump(2)   // let the device settle and macOS re-parse

    let rdLen = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data)?.count ?? -1
    let usage = describePressureUsage()

    logline("======== MODE '\(name)' ========")
    logline("  SET_REPORT        : \(status)")
    logline("  descriptor        : \(rdLen) bytes")
    logline("  digitizer usages  : \(usage)")

    lastEventAt = .distantPast
    logline("")
    logline("  >>> waiting for your pen — stroke it now (hard and soft)")
    let gotPen = waitForPen(timeout: 300)
    guard gotPen else {
        logline("  no pen activity within 5 minutes — skipping this mode")
        logline("")
        results.append((name, 0, 0.0, usage, false))
        continue
    }

    maxPressure = 0.0
    pointerEvents = 0
    logline("  pen detected — measuring for \(Int(window))s, keep stroking")
    pump(window)

    let pct = maxPressure * 100
    logline("  tabletPointer     : \(pointerEvents)")
    logline("  MAX PRESSURE      : \(String(format: "%.8f", maxPressure))  (\(String(format: "%.3f", pct))% of full scale)")
    let ok = maxPressure >= PRESSURE_THRESHOLD
    logline("  verdict           : \(ok ? "USABLE PRESSURE" : "no usable pressure")")
    logline("")
    results.append((name, pointerEvents, maxPressure, usage, ok))
}

logline("================ SUMMARY ================")
logline("  MODE       tabletPointer   maxPressure    usable   digitizer usages")
for r in results {
    logline(String(format: "  %-10@ %14d %13.6f    %-7@ %@",
                   r.name as NSString, r.events, r.peak, (r.ok ? "YES" : "no") as NSString, r.usage as NSString))
}
let winners = results.filter { $0.ok }.map { $0.name }
logline("")
if winners.isEmpty {
    logline("VERDICT: no mode delivers usable pressure. A descriptor-correcting kext is required.")
} else {
    logline("VERDICT: usable pressure in mode(s): \(winners.joined(separator: ", ")) — no kext needed.")
}
logline("==========================================")