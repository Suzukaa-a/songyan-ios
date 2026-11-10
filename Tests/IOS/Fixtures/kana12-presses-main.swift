import CoreGraphics

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL \(message)")
        exit(1)
    }
}

let cell: CGFloat = 40
let a = Kana12KanaRows.rowA
let ka = Kana12KanaRows.rowKa
let ta = Kana12KanaRows.rowTa

// Two thumbs overlap: あ goes down, か goes down, あ lifts, か lifts. Both type, in release order.
var presses = Kana12Presses()
presses.move(rowID: a.id, translation: .zero, cell: cell)
presses.move(rowID: ka.id, translation: .zero, cell: cell)
check(presses.isPressed(a.id) && presses.isPressed(ka.id), "both keys show pressed")
check(presses.preview?.rowID == ka.id, "the newest press owns the preview")
check(presses.end(a, translation: .zero, cell: cell) == .kana(rowId: a.id, direction: .center), "first key types")
check(presses.end(ka, translation: .zero, cell: cell) == .kana(rowId: ka.id, direction: .center), "second key types")
check(presses.end(ka, translation: .zero, cell: cell) == nil, "a release types once")

// A flick held under one thumb while the other taps still types its direction.
presses.move(rowID: ta.id, translation: CGSize(width: 0, height: -30), cell: cell)
presses.move(rowID: a.id, translation: .zero, cell: cell)
check(presses.end(a, translation: .zero, cell: cell) == .kana(rowId: a.id, direction: .center), "tap during flick")
check(
    presses.end(ta, translation: CGSize(width: 0, height: -30), cell: cell) == .kana(rowId: ta.id, direction: .up),
    "flick keeps its direction")

// Dragged past the cancel distance and back types nothing.
presses.move(rowID: a.id, translation: CGSize(width: 200, height: 0), cell: cell)
presses.move(rowID: a.id, translation: .zero, cell: cell)
check(presses.end(a, translation: .zero, cell: cell) == nil, "a cancelled press stays cancelled")
check(presses == Kana12Presses(), "every release clears its key")
print("OK")
