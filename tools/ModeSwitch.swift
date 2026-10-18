// ModeSwitch.swift
//
// Sends the WALTOP Slim Tablet HID feature report that switches the device
// between its input modes, then measures whether macOS now delivers pressure.
//
// Modes are selected by a 3-byte feature report (from drivers/hid/hid-waltop.c):
//     02 16 00   default   — HID-compatible, but pressure is mislabelled
//     02 16 01   tablet    — proprietary protocol, true resolution
//     02 16 02   ink       — purpose unknown
//
// i.e. reportID 2, then the mode command byte 0x16, then the mode byte.
//
// USAGE:
//   ./ModeSwitch              show current mode + list supported modes
//   ./ModeSwitch default      switch to default mode
//   ./ModeSwitch tablet       switch to tablet mode
//   ./ModeSwitch ink          switch to ink mode
//   ./ModeSwitch tablet --watch   switch, then watch pressure for 30s
//
// QUIT KRITA (and any other app holding the tablet) FIRST. If the device is
// already open by another client the SET_REPORT will fail with a busy error.
//
// Switching is reversible: run `./ModeSwitch default` to return. Unplugging the
// tablet also resets it to default.
//
// Build: swiftc -O -o ModeSwitch ModeSwitch.swift

import Foundation
import IOKit.hid
import CoreGraphics

let VENDOR = 0x172F
let PRODUCT = 0x0031
let MODE_REPORT_ID: UInt8 = 2
let MODE_COMMAND: UInt8 = 0x16

private func logline(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

private let modes: [String: UInt8] = ["default": 0x00, "tablet": 0x01, "ink": 0x02]

private var maxPressure = 0.0
private var pointerEvents = 0

let args = CommandLine.arguments.dropFirst()
let requested = args.first ?? "show"
let watch = args.contains("--watch")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching = [kIOHIDVendorIDKey as String: NSNumber(value: VENDOR),
                kIOHIDProductIDKey as String: NSNumber(value: PRODUCT)] as CFDictionary
IOHIDManagerSetDeviceMatching(manager, matching)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
logline("[hid] open = \(openResult)")

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty,
      let device = devices.first else {
    logline("[err] tablet not found — is it plugged in?")
    exit(1)
}

let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
logline("[hid] found: \(name)  \(String(format: "%04x:%04x", VENDOR, PRODUCT))")

// Report what the device advertises for feature reports.
let maxFeature = (IOHIDDeviceGetProperty(device, "MaxFeatureReportSize" as CFString) as? NSNumber)?.intValue ?? -1
logline("[hid] MaxFeatureReportSize = \(maxFeature) byte(s)")

if requested == "show" {
    logline("[hid] supported modes:")
    for (k, v) in modes.sorted(by: { $0.value < $1.value }) {
        logline("        \(k.padding(toLength: 8, withPad: " ", startingAt: 0)) -> feature report \(MODE_REPORT_ID) \(MODE_COMMAND) \(v)")
    }
    logline("[hid] the tablet does not report its current mode; there is no getter in the protocol.")
    logline("[hid] run './ModeSwitch tablet --watch' to try one and measure pressure.")
    exit(0)
}

guard let modeByte = modes[requested] else {
    logline("[err] unknown mode '\(requested)'. Use: \(modes.keys.sorted().joined(separator: ", "))")
    exit(1)
}

var payload: [UInt8] = [MODE_COMMAND, modeByte]
let status = IOHIDDeviceSetReport(device,
                                  kIOHIDReportTypeFeature,
                                  CFIndex(MODE_REPORT_ID),
                                  &payload,
                                  CFIndex(payload.count))

logline("[hid] SET_REPORT feature id=\(MODE_REPORT_ID) bytes=[\(MODE_COMMAND) \(modeByte)] -> \(status) (\(status))")
if status != kIOReturnSuccess {
    logline("[err] feature report failed. Most likely another app (Krita?) is holding the tablet — quit it and retry.")
    exit(1)
}
logline("[hid] mode -> '\(requested)'. Give the tablet a moment, then stroke the pen.")
logline("[note] if the pen stops responding entirely, unplug/replug the tablet to restore default mode.")

// If watching, install a CGEventTap and report what macOS actually delivers.
if watch {
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

    // C callbacks cannot capture context, so the counters live in globals above.
    let tapCallback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tabletPointer {
            pointerEvents += 1
            let p = event.getDoubleValueField(.tabletEventPointPressure)
            if p > maxPressure { maxPressure = p }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: CGEventTapOptions(rawValue: 0)!,
        eventsOfInterest: CGEventMask(1 << UInt64(CGEventType.tabletPointer.rawValue)),
        callback: tapCallback,
        userInfo: nil
    ) else {
        logline("[err] could not create CGEventTap (needs Input Monitoring permission)")
        exit(1)
    }

    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    logline("[watch] STROKE THE PEN NOW - varying pressure hard to soft, for 30s.")
    logline("[watch] (expected if broken: maxPressure=0.0000)")

    // Print progress continuously so an early Ctrl-C still leaves usable data.
    Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
        logline(String(format: "[live] mode=%@ tabletPointer=%d maxPressure=%.4f",
                       requested, pointerEvents, maxPressure))
    }

    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    logline("")
    logline("================ RESULT (mode: \(requested)) ================")
    logline("tabletPointer events : \(pointerEvents)")
    logline("maxPressure observed : \(String(format: "%.4f", maxPressure))")
    if pointerEvents == 0 {
        logline("VERDICT: no tablet events at all — the pen may have stopped working in this mode.")
    } else if maxPressure > 0.0 {
        logline("VERDICT: PRESSURE IS WORKING in '\(requested)' mode — macOS is receiving it!")
        logline("         No kext needed. Remember to check whether position/buttons are still correct.")
    } else {
        logline("VERDICT: pressure still 0.0000 — mode '\(requested)' does not fix it; kext required.")
    }
    logline("===========================================================")
}