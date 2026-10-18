// selftest.swift
// Isolates the synthetic-event path: installs a CGEventTap, posts a synthetic
// tabletPointer, and reports whether the tap actually observes it.
//
// This separates "posting is broken" from "the app ignores synthetic tablets".

import Cocoa
import CoreGraphics

var seen = 0
var seenPressure: Double = -1

let cb: CGEventTapCallBack = { _, type, event, _ in
    if type == .tabletPointer || type == .tabletProximity {
        seen += 1
        seenPressure = event.getDoubleValueField(.tabletEventPointPressure)
        print("TAP SAW: \(type == .tabletPointer ? "tabletPointer" : "tabletProximity") pressure=\(seenPressure)")
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: CGEventTapOptions(rawValue: 0)!,
                                 eventsOfInterest: CGEventMask(1 << UInt64(CGEventType.tabletPointer.rawValue))
                                    | CGEventMask(1 << UInt64(CGEventType.tabletProximity.rawValue)),
                                 callback: cb, userInfo: nil) else {
    print("tap creation failed"); exit(1)
}
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

func pump(_ s: Double) {
    let d = Date().addingTimeInterval(s)
    while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

let bounds = CGDisplayBounds(CGMainDisplayID())
let cx = bounds.midX, cy = bounds.midY

// Post proximity (tablet "in range") first - Qt-based apps generally need this
// before tablet update events mean anything.
let prox = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
prox.type = .tabletProximity
prox.location = CGPoint(x: cx, y: cy)
prox.post(tap: .cghidEventTap)
pump(0.2)

// Post a pointer event with unmistakable pressure.
let e = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
e.type = .tabletPointer
e.location = CGPoint(x: cx, y: cy)
e.setDoubleValueField(.tabletEventPointPressure, value: 1.0)
e.setIntegerValueField(.tabletEventDeviceID, value: 1)
e.setIntegerValueField(.mouseEventClickState, value: 1)
e.post(tap: .cghidEventTap)
pump(0.5)

print("")
print("RESULT: tap observed \(seen) tablet event(s)")
if seen == 0 {
    print("=> Posting is NOT reaching the session tap. Synthetic events are not being delivered.")
} else {
    print("=> Posting works (pressure seen: \(seenPressure)).")
    print("   If the app still shows nothing, the app is ignoring synthetic tablet events.")
}