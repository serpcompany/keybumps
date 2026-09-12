import Carbon.HIToolbox
import Foundation

enum SuperMacWindowAction: String, CaseIterable, Identifiable {
    case left, right, centerHalf, top, bottom, upperLeft, upperRight, lowerLeft, lowerRight
    case maximize, smaller, larger, center, restore, nextDisplay, previousDisplay
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case lastFourth, firstThreeFourths, lastThreeFourths

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "Left"; case .right: "Right"; case .centerHalf: "Center Half"
        case .top: "Top"; case .bottom: "Bottom"; case .upperLeft: "Top Left"; case .upperRight: "Top Right"
        case .lowerLeft: "Bottom Left"; case .lowerRight: "Bottom Right"; case .maximize: "Maximize"
        case .smaller: "Make Smaller"; case .larger: "Make Larger"; case .center: "Move to Center"; case .restore: "Restore"
        case .nextDisplay: "Next Display"; case .previousDisplay: "Previous Display"
        case .firstThird: "First Third"; case .centerThird: "Center Third"; case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"; case .lastTwoThirds: "Last Two Thirds"
        case .topLeftSixth: "Top Left Sixth"; case .topCenterSixth: "Top Center Sixth"; case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"; case .bottomCenterSixth: "Bottom Center Sixth"; case .bottomRightSixth: "Bottom Right Sixth"
        case .lastFourth: "Last Fourth"; case .firstThreeFourths: "First Three Fourths"; case .lastThreeFourths: "Last Three Fourths"
        }
    }

    var defaultShortcut: ShortcutBinding? {
        let co = UInt32(controlKey | optionKey)
        let coc = UInt32(controlKey | optionKey | cmdKey)
        let cosc = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        switch self {
        case .left: return .init(keyCode: UInt32(kVK_LeftArrow), modifiers: coc, displayName: "⌃⌥⌘←")
        case .right: return .init(keyCode: UInt32(kVK_RightArrow), modifiers: coc, displayName: "⌃⌥⌘→")
        case .centerHalf: return .init(keyCode: UInt32(kVK_ANSI_5), modifiers: coc, displayName: "⌃⌥⌘5")
        case .top: return .init(keyCode: UInt32(kVK_UpArrow), modifiers: cosc, displayName: "⌃⌥⇧⌘↑")
        case .bottom: return .init(keyCode: UInt32(kVK_DownArrow), modifiers: cosc, displayName: "⌃⌥⇧⌘↓")
        case .upperLeft: return .init(keyCode: UInt32(kVK_ANSI_U), modifiers: co, displayName: "⌃⌥U")
        case .lowerLeft: return .init(keyCode: UInt32(kVK_ANSI_J), modifiers: co, displayName: "⌃⌥J")
        case .lowerRight: return .init(keyCode: UInt32(kVK_ANSI_K), modifiers: co, displayName: "⌃⌥K")
        case .maximize: return .init(keyCode: UInt32(kVK_UpArrow), modifiers: coc, displayName: "⌃⌥⌘↑")
        case .smaller: return .init(keyCode: UInt32(kVK_ANSI_Minus), modifiers: co, displayName: "⌃⌥-")
        case .larger: return .init(keyCode: UInt32(kVK_ANSI_Equal), modifiers: co, displayName: "⌃⌥=")
        case .center: return .init(keyCode: UInt32(kVK_ANSI_M), modifiers: coc, displayName: "⌃⌥⌘M")
        case .restore: return .init(keyCode: UInt32(kVK_Delete), modifiers: co, displayName: "⌃⌥⌫")
        case .nextDisplay: return .init(keyCode: UInt32(kVK_RightArrow), modifiers: co, displayName: "⌃⌥→")
        case .previousDisplay: return .init(keyCode: UInt32(kVK_LeftArrow), modifiers: co, displayName: "⌃⌥←")
        case .firstThird: return .init(keyCode: UInt32(kVK_ANSI_1), modifiers: coc, displayName: "⌃⌥⌘1")
        case .centerThird: return .init(keyCode: UInt32(kVK_ANSI_2), modifiers: coc, displayName: "⌃⌥⌘2")
        case .lastThird: return .init(keyCode: UInt32(kVK_ANSI_3), modifiers: coc, displayName: "⌃⌥⌘3")
        case .firstTwoThirds: return .init(keyCode: UInt32(kVK_ANSI_4), modifiers: coc, displayName: "⌃⌥⌘4")
        case .lastTwoThirds: return .init(keyCode: UInt32(kVK_ANSI_6), modifiers: coc, displayName: "⌃⌥⌘6")
        case .topLeftSixth: return .init(keyCode: UInt32(kVK_ANSI_4), modifiers: cosc, displayName: "⌃⌥⇧⌘4")
        case .topCenterSixth: return .init(keyCode: UInt32(kVK_ANSI_5), modifiers: cosc, displayName: "⌃⌥⇧⌘5")
        case .topRightSixth: return .init(keyCode: UInt32(kVK_ANSI_6), modifiers: cosc, displayName: "⌃⌥⇧⌘6")
        case .bottomLeftSixth: return .init(keyCode: UInt32(kVK_ANSI_7), modifiers: cosc, displayName: "⌃⌥⇧⌘7")
        case .bottomCenterSixth: return .init(keyCode: UInt32(kVK_ANSI_8), modifiers: cosc, displayName: "⌃⌥⇧⌘8")
        case .bottomRightSixth: return .init(keyCode: UInt32(kVK_ANSI_9), modifiers: cosc, displayName: "⌃⌥⇧⌘9")
        case .lastFourth: return .init(keyCode: UInt32(kVK_End), modifiers: coc, displayName: "⌃⌥⌘↘")
        case .firstThreeFourths: return .init(keyCode: UInt32(kVK_ANSI_7), modifiers: coc, displayName: "⌃⌥⌘7")
        case .lastThreeFourths: return .init(keyCode: UInt32(kVK_ANSI_9), modifiers: coc, displayName: "⌃⌥⌘9")
        case .upperRight: return nil
        }
    }
}
