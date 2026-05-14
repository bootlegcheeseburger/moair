import AppKit

/// 3×3 grid spritesheet of moai-style head poses for the menubar icon.
/// Columns are yaw (left, centre, right); rows are pitch (up, level,
/// down). Sliced once on first use into nine NSImages, cached, and
/// re-served as the user's head moves so the menubar glyph visibly
/// follows them.
enum MoaiSprite {
    static let cols = 3
    static let rows = 3

    /// ±deg from centre that still counts as the centre bucket. Tight
    /// values make the sprite feel responsive — head moves before the
    /// user has to deliberately swivel.
    static let yawDeadband: Double = 5
    static let pitchDeadband: Double = 5

    private static let cached: [[NSImage]] = loadGrid()

    static func image(yawDeg: Double, pitchDeg: Double) -> NSImage {
        let col = max(-1, min(1, bucket(value: yawDeg, deadband: yawDeadband))) + 1
        // Pitch row: 0 = up (top of sheet), 2 = down (bottom).
        // CMHeadphoneMotionManager reports +pitch when the user looks up,
        // so higher pitch means a *lower* row index.
        let row = 1 - max(-1, min(1, bucket(value: pitchDeg, deadband: pitchDeadband)))
        let r = max(0, min(rows - 1, row))
        let c = max(0, min(cols - 1, col))
        return cached[r][c]
    }

    /// Returns -1 / 0 / +1 keyed off the deadband around 0.
    private static func bucket(value: Double, deadband: Double) -> Int {
        if value < -deadband { return -1 }
        if value >  deadband { return  1 }
        return 0
    }

    private static func loadGrid() -> [[NSImage]] {
        let fallback = NSImage()
        // MenubarResources avoids Bundle.module's fatalError on miss —
        // see MenubarResources.swift.
        guard let sheet = MenubarResources.image(named: "moai-grid") else {
            return Array(repeating: Array(repeating: fallback, count: cols), count: rows)
        }
        let cellW = sheet.size.width  / CGFloat(cols)
        let cellH = sheet.size.height / CGFloat(rows)
        return (0..<rows).map { r in
            (0..<cols).map { c in
                let cell = NSImage(size: NSSize(width: cellW, height: cellH))
                cell.lockFocus()
                // NSImage origin is bottom-left, so we invert the row to
                // sample the visually-top cell first.
                let src = NSRect(
                    x: CGFloat(c) * cellW,
                    y: sheet.size.height - CGFloat(r + 1) * cellH,
                    width: cellW, height: cellH
                )
                let dst = NSRect(origin: .zero, size: cell.size)
                sheet.draw(in: dst, from: src, operation: .copy, fraction: 1.0)
                cell.unlockFocus()
                cell.isTemplate = true
                return cell
            }
        }
    }
}
