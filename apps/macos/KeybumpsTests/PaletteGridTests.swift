import Testing
@testable import Keybumps

@Suite("Command Palette: moving through a grid in sections")
struct PaletteGridTests {
    /// Two sections in rows of 4: [0 1 2 3] [4 5] then [6 7 8 9] [10].
    private let sections = [6, 5]

    private func move(_ move: PaletteMove, from index: Int) -> Int? {
        PaletteGrid.selection(after: move, from: index, sectionCounts: sections, columns: 4)
    }

    @Test("Left and Right step one item, across rows and sections, and stop at the ends")
    func leftAndRight() {
        #expect(move(.right, from: 3) == 4)
        #expect(move(.right, from: 5) == 6, "Into the next section")
        #expect(move(.left, from: 6) == 5)
        #expect(move(.left, from: 0) == nil)
        #expect(move(.right, from: 10) == nil)
    }

    @Test("Up and Down keep the column, or land on the last item of a shorter row")
    func upAndDown() {
        #expect(move(.down, from: 1) == 5)
        #expect(move(.down, from: 3) == 5, "The row below is shorter")
        #expect(move(.down, from: 5) == 7, "A section starts a new row")
        #expect(move(.up, from: 8) == 5, "Up into a shorter row")
        #expect(move(.up, from: 10) == 6)
        #expect(move(.up, from: 2) == nil)
        #expect(move(.down, from: 10) == nil)
    }

    @Test("Empty sections take no rows, and an index out of range goes nowhere")
    func edges() {
        #expect(PaletteGrid.selection(after: .down, from: 0, sectionCounts: [2, 0, 3], columns: 4) == 2)
        #expect(PaletteGrid.selection(after: .right, from: 99, sectionCounts: sections, columns: 4) == nil)
        #expect(PaletteGrid.selection(after: .down, from: 0, sectionCounts: [], columns: 4) == nil)
    }

    @Test("Arrow key codes map to moves")
    func keyCodes() {
        #expect(PaletteMove(keyCode: 123) == .left)
        #expect(PaletteMove(keyCode: 124) == .right)
        #expect(PaletteMove(keyCode: 125) == .down)
        #expect(PaletteMove(keyCode: 126) == .up)
        #expect(PaletteMove(keyCode: 36) == nil)
    }
}
