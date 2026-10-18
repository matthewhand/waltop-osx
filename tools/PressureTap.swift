// PressureTap.swift
//
// Observes tablet pressure exactly as macOS delivers it to applications,
// using a CGEventTap. Unlike a raw IOHIDManager probe, a CGEventTap does NOT
// seize the HID device, so this can run while another application (e.g. Krita)
// is holding the tablet.
//
// On the tested machine this reports pressure=0.0000 for every tabletPointer
// event, which is the defect described in README.md.
//
// Build: swiftc -O -o PressureTap PressureTap.swift
// Run:   ./PressureTap      (then stroke the pen; Ctrl-C to stop)

import Cocoa
import CoreGraphics

// macOS normalises tablet pressure to 0.0-1.0 at the CGEvent layer, NOT 0-1023.
private func logline(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

var maxPressure: Double = 0
var sampleCount = 0
var lastType = "—"

private func describe(_ type: CGEventType) -> String {
    switch type {
    case .tabletPointer: return "tabletPointer"
    case .tabletProximity: return "tabletProximity"
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return "mouse"
    case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return "rightMouse"
    default: return "other(\(type.rawValue))"
    }
}

private let callback: CGEventTapCallBack = { _, type, event, _ in
    let name = describe(type)
    lastType = name

    let pressure = event.getDoubleValueField(.tabletEventPointPressure)
    let tiltX = event.getDoubleValueField(.tabletEventTiltX)
    let tiltY = event.getDoubleValueField(.tabletEventTiltY)
    let rotation = event.getDoubleValueField(.tabletEventRotation)
    let deviceID = event.getIntegerValueField(.tabletEventDeviceID)
    let tangential = event.getDoubleValueField(.tabletEventTangentialPressure)
    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    sampleCount += 1
    if pressure > maxPressure { maxPressure = pressure }

    if type == .tabletPointer || button != 0 {
        logline(String(format: "%@ pressure=%.4f tilt=(%.2f,%.2f) rot=%.2f devID=%d tang=%.2f btn=%d maxSoFar=%.4f",
                       name, pressure, tiltX, tiltY, rotation, deviceID, tangential, button, maxPressure))
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: CGEventTapOptions(rawValue: 0)!,
    eventsOfInterest: CGEventMask(1 << UInt64(CGEventType.tabletPointer.rawValue))
        | CGEventMask(1 << UInt64(CGEventType.tabletProximity.rawValue)),
    callback: callback,
    userInfo: nil
) else {
    logline("[tap] FAILED to create CGEventTap — needs Input Monitoring / Accessibility permission")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

logline("[tap] active — stroke the pen. Watch pressure= (expect 0.0000 = the bug).")
logline("[tap] Ctrl-C to stop.")

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    logline(String(format: "[summary] samples=%d lastEvent=%@ maxPressure=%.4f",
                   sampleCount, lastType, maxPressure))
}

RunLoop.main.run()