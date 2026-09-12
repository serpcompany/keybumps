import CoreGraphics

enum WindowGeometry {
    static func frame(for action: CompanionWindowAction, in screen: CGRect, current: CGRect) -> CGRect {
        let x = screen.minX, y = screen.minY, w = screen.width, h = screen.height
        switch action {
        case .left: return CGRect(x: x, y: y, width: w / 2, height: h)
        case .right: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .centerHalf: return CGRect(x: x + w / 4, y: y, width: w / 2, height: h)
        case .top: return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .bottom: return CGRect(x: x, y: y, width: w, height: h / 2)
        case .upperLeft: return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .upperRight: return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .lowerLeft: return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .lowerRight: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .maximize: return screen
        case .smaller:
            let nw = max(320, current.width * 0.9), nh = max(240, current.height * 0.9)
            return CGRect(x: current.midX - nw / 2, y: current.midY - nh / 2, width: nw, height: nh)
        case .larger:
            let nw = min(w, current.width * 1.1), nh = min(h, current.height * 1.1)
            return CGRect(x: current.midX - nw / 2, y: current.midY - nh / 2, width: nw, height: nh).intersection(screen)
        case .center: return CGRect(x: x + (w - current.width) / 2, y: y + (h - current.height) / 2, width: current.width, height: current.height)
        case .firstThird: return CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .lastThird: return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .firstTwoThirds: return CGRect(x: x, y: y, width: 2 * w / 3, height: h)
        case .lastTwoThirds: return CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
        case .topLeftSixth: return sixth(column: 0, top: true, in: screen)
        case .topCenterSixth: return sixth(column: 1, top: true, in: screen)
        case .topRightSixth: return sixth(column: 2, top: true, in: screen)
        case .bottomLeftSixth: return sixth(column: 0, top: false, in: screen)
        case .bottomCenterSixth: return sixth(column: 1, top: false, in: screen)
        case .bottomRightSixth: return sixth(column: 2, top: false, in: screen)
        case .lastFourth: return CGRect(x: x + 3 * w / 4, y: y, width: w / 4, height: h)
        case .firstThreeFourths: return CGRect(x: x, y: y, width: 3 * w / 4, height: h)
        case .lastThreeFourths: return CGRect(x: x + w / 4, y: y, width: 3 * w / 4, height: h)
        case .restore, .nextDisplay, .previousDisplay: return current
        }
    }

    private static func sixth(column: CGFloat, top: Bool, in s: CGRect) -> CGRect {
        CGRect(x: s.minX + column * s.width / 3, y: s.minY + (top ? s.height / 2 : 0), width: s.width / 3, height: s.height / 2)
    }
}
