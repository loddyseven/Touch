import AppKit

@MainActor func marqueeChecks(check: (Bool, String) -> Void) {
    let a = URL(fileURLWithPath: "/tmp/selection-a.png")
    let b = URL(fileURLWithPath: "/tmp/selection-b.png")
    let c = URL(fileURLWithPath: "/tmp/selection-c.png")
    let canvas = MarqueeCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
    canvas.itemFrames = [a: NSRect(x: 10, y: 10, width: 80, height: 50),
                         b: NSRect(x: 110, y: 10, width: 80, height: 50),
                         c: NSRect(x: 210, y: 10, width: 80, height: 50)]
    var selected: Set<URL> = [c]
    var active = false
    canvas.currentSelection = { selected }
    canvas.setSelection = { selected = $0 }
    canvas.selectionActivity = { active = $0 }

    canvas.beginMarquee(at: .zero)
    check(active && selected.isEmpty, "Starting a replacement marquee clears the old selection and keeps the panel open")
    canvas.moveMarquee(to: NSPoint(x: 195, y: 65))
    check(selected == [a, b], "A marquee selects every intersected item, excluding items outside it")
    canvas.moveMarquee(to: NSPoint(x: 95, y: 65))
    check(selected == [a], "Shrinking the rectangle removes items that are no longer inside")
    canvas.moveMarquee(to: NSPoint(x: 1, y: 1))
    check(selected.isEmpty, "Shrinking back to the starting point does not leave stale selection")
    canvas.moveMarquee(to: NSPoint(x: 195, y: 65)); canvas.finishMarquee()
    check(!active && selected == [a, b], "Mouse-up keeps the selected group and releases the panel drag guard")

    canvas.beginMarquee(at: NSPoint(x: 195, y: 65))
    canvas.moveMarquee(to: .zero); canvas.finishMarquee()
    check(selected == [a, b], "Dragging a rectangle backwards selects the same items")
    canvas.beginMarquee(at: NSPoint(x: 205, y: 0), flags: .shift)
    canvas.moveMarquee(to: NSPoint(x: 295, y: 65)); canvas.finishMarquee()
    check(selected == [a, b, c], "Shift adds a rectangle to the existing selection")
    canvas.beginMarquee(at: .zero, flags: .command)
    canvas.moveMarquee(to: NSPoint(x: 195, y: 65))
    canvas.moveMarquee(to: NSPoint(x: 195, y: 65))
    check(selected == [c], "Command toggles against the initial selection, without flickering on repeated mouse events")
    canvas.moveMarquee(to: NSPoint(x: 95, y: 65))
    check(selected == [b, c], "A shrinking Command rectangle restores entries outside the new rectangle")
    canvas.finishMarquee(cancelled: true)
    check(selected == [a, b, c] && !active, "Cancelling a marquee restores the exact original selection")
    canvas.beginMarquee(at: NSPoint(x: 350, y: 100)); canvas.finishMarquee()
    check(selected.isEmpty, "Clicking blank space clears selection without exporting any files")

    let menu = NSMenu(title: "Selection")
    canvas.makeSelectionMenu = { menu }
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    check(canvas.menu(for: event) == nil, "Blank space offers no selected-file actions when nothing is selected")
    selected = [a, b]
    check(canvas.menu(for: event) === menu && selected == [a, b], "Right-clicking blank space exposes actions for the whole selected group")
}
