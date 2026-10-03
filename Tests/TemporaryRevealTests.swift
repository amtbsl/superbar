import CoreGraphics

enum TemporaryRevealTests {
    static func run() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let main = CGRect(x: 1100, y: 949, width: 26, height: 33)
        let blank = CGRect(x: 420, y: 949, width: 676, height: 33)
        try expect(MenuTemporaryRevealGeometry.targetX(width: 36, screen: screen, main: main,
            blank: blank, notchRight: 846, firstVisible: main) == 1064,
            "A hidden icon uses the divider-derived blank edge, not MAIN's insertion edge")
        let cramped = CGRect(x: 420, y: 949, width: 80, height: 33)
        try expect(MenuTemporaryRevealGeometry.targetX(width: 36, screen: screen, main: main,
            blank: cramped, notchRight: 846, firstVisible: CGRect(x: 1000, y: 949, width: 20, height: 33)) == 968,
            "An unusable notch-side space falls back to the first on-screen renderer")
        let beyondMain = CGRect(x: 420, y: 949, width: 900, height: 33)
        try expect(MenuTemporaryRevealGeometry.targetX(width: 36, screen: screen, main: main,
            blank: beyondMain, notchRight: nil, firstVisible: main) == 1081,
            "Space to MAIN's right uses the reference conditional rather than min(candidate, center-width)")
        let second = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let secondMain = main.offsetBy(dx: -1512, dy: 0)
        try expect(MenuTemporaryRevealGeometry.targetX(width: 36, screen: second, main: secondMain,
            blank: blank, notchRight: 846, firstVisible: secondMain) == -448,
            "A display left of the primary uses local blank coordinates and signed screen X")
        try expect(MenuTemporaryRevealGeometry.targetX(width: .infinity, screen: screen, main: main,
            blank: blank, notchRight: nil, firstVisible: main) == nil,
            "Invalid native dimensions cannot become a synthetic event destination")
    }
}
