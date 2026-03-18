import AppKit

class PlantMenuBarView: NSView {
    weak var vm: PlantViewModel?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let vm else { return }
        ctx.clear(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let sway   = sin(vm.swayPhase)
        let stage  = vm.stage

        let cx     = bounds.width / 2
        let groundY: CGFloat = 3   // stem root — near bottom of bar

        // Soil line (tiny, just a hint of ground)
        let soilColor = isDark
            ? CGColor(red: 0.40, green: 0.26, blue: 0.10, alpha: 0.7)
            : CGColor(red: 0.30, green: 0.16, blue: 0.05, alpha: 0.6)
        ctx.setFillColor(soilColor)
        ctx.fillEllipse(in: CGRect(x: cx - 6, y: groundY - 1, width: 12, height: 3))

        drawPlant(ctx: ctx, cx: cx, groundY: groundY, sway: sway, stage: stage,
                  needsCare: vm.needsCare, celebrating: vm.isCelebrating, isDark: isDark)

        if vm.needsCare {
            drawAlertDot(ctx: ctx)
        }
    }

    // MARK: - Plant

    private func drawPlant(ctx: CGContext, cx: CGFloat, groundY: CGFloat,
                            sway: CGFloat, stage: PlantStage,
                            needsCare: Bool, celebrating: Bool, isDark: Bool) {

        // Stem heights per stage — use almost full bar height now
        let stemHeights: [CGFloat] = [0, 10, 14, 17, 17]
        let stemH = stemHeights[min(stage.rawValue, 4)]

        // Colors
        let stemC = isDark ? CGColor(red: 0.25, green: 0.72, blue: 0.15, alpha: 1)
                           : CGColor(red: 0.15, green: 0.55, blue: 0.08, alpha: 1)
        let leaf1 = isDark ? CGColor(red: 0.32, green: 0.82, blue: 0.22, alpha: 1)
                           : CGColor(red: 0.18, green: 0.65, blue: 0.10, alpha: 1)
        let leaf2 = isDark ? CGColor(red: 0.22, green: 0.68, blue: 0.14, alpha: 1)
                           : CGColor(red: 0.12, green: 0.52, blue: 0.06, alpha: 1)
        let leaf3 = isDark ? CGColor(red: 0.40, green: 0.88, blue: 0.28, alpha: 1)
                           : CGColor(red: 0.26, green: 0.75, blue: 0.14, alpha: 1)

        if stemH == 0 {
            // Seed: just a tiny green dot above soil
            ctx.setFillColor(leaf2)
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: groundY + 1, width: 4, height: 3))
            return
        }

        let swayAmt: CGFloat = needsCare ? sway * 3.5 : sway * 1.5
        let tipX = cx + swayAmt
        let tipY = groundY + stemH

        // Stem
        ctx.setStrokeColor(stemC)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        let stemPath = CGMutablePath()
        stemPath.move(to: CGPoint(x: cx, y: groundY + 1))
        stemPath.addQuadCurve(
            to: CGPoint(x: tipX, y: tipY),
            control: CGPoint(x: cx + swayAmt * 0.4, y: groundY + stemH * 0.5)
        )
        ctx.addPath(stemPath)
        ctx.strokePath()

        let midX = cx + swayAmt * 0.45
        let midY = groundY + stemH * 0.50

        // Sprout+: two tip leaves
        if stage.rawValue >= 1 {
            drawLeaf(ctx: ctx, base: CGPoint(x: tipX, y: tipY), angle: .pi * 0.28, size: 6, color: leaf1)
            drawLeaf(ctx: ctx, base: CGPoint(x: tipX, y: tipY), angle: .pi * 0.72, size: 6, color: leaf2)
        }
        // Seedling+: mid leaves
        if stage.rawValue >= 2 {
            drawLeaf(ctx: ctx, base: CGPoint(x: midX, y: midY), angle: .pi * 0.18, size: 7, color: leaf2)
            drawLeaf(ctx: ctx, base: CGPoint(x: midX, y: midY), angle: .pi * 0.82, size: 7, color: leaf1)
        }
        // Plant+: lower larger leaves
        if stage.rawValue >= 3 {
            let lowX = cx + swayAmt * 0.18
            let lowY = groundY + stemH * 0.24
            drawLeaf(ctx: ctx, base: CGPoint(x: lowX, y: lowY), angle: .pi * 0.14, size: 9, color: leaf3)
            drawLeaf(ctx: ctx, base: CGPoint(x: lowX, y: lowY), angle: .pi * 0.86, size: 9, color: leaf2)
        }
        // Bloom: flower at tip
        if stage == .bloom {
            let p1 = CGColor(red: 1.0, green: 0.56, blue: 0.70, alpha: 1)
            let p2 = CGColor(red: 1.0, green: 0.78, blue: 0.86, alpha: 1)
            drawFlower(ctx: ctx, at: CGPoint(x: tipX, y: tipY + 4), petal1: p1, petal2: p2)
        }
        // Celebrate sparkles
        if celebrating {
            drawSparkles(ctx: ctx, tip: CGPoint(x: tipX, y: tipY))
        }
    }

    // MARK: - Leaf

    private func drawLeaf(ctx: CGContext, base: CGPoint, angle: CGFloat, size: CGFloat, color: CGColor) {
        let tip  = CGPoint(x: base.x + cos(angle) * size,
                           y: base.y + sin(angle) * size * 0.75)
        let c1   = CGPoint(x: base.x + cos(angle - 0.45) * size * 0.85,
                           y: base.y + sin(angle - 0.45) * size * 0.65)
        let c2   = CGPoint(x: base.x + cos(angle + 0.45) * size * 0.85,
                           y: base.y + sin(angle + 0.45) * size * 0.65)
        let path = CGMutablePath()
        path.move(to: base)
        path.addQuadCurve(to: tip, control: c1)
        path.addQuadCurve(to: base, control: c2)
        path.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(path); ctx.fillPath()

        // vein
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
        ctx.setLineWidth(0.5)
        let vein = CGMutablePath()
        vein.move(to: base); vein.addLine(to: tip)
        ctx.addPath(vein); ctx.strokePath()
    }

    // MARK: - Flower

    private func drawFlower(ctx: CGContext, at center: CGPoint, petal1: CGColor, petal2: CGColor) {
        for i in 0..<5 {
            let a  = CGFloat(i) * (2 * .pi / 5) - .pi / 2
            let px = center.x + cos(a) * 3.8
            let py = center.y + sin(a) * 3.0
            ctx.setFillColor(i % 2 == 0 ? petal1 : petal2)
            ctx.fillEllipse(in: CGRect(x: px - 2, y: py - 2, width: 4, height: 4))
        }
        ctx.setFillColor(CGColor(red: 1.0, green: 0.85, blue: 0.10, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4))
        ctx.setFillColor(CGColor(red: 0.90, green: 0.55, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2))
    }

    // MARK: - Sparkles

    private func drawSparkles(ctx: CGContext, tip: CGPoint) {
        let t = CACurrentMediaTime()
        let colors: [CGColor] = [
            CGColor(red: 1.0, green: 0.85, blue: 0.10, alpha: 1),
            CGColor(red: 0.35, green: 0.90, blue: 0.28, alpha: 1),
            CGColor(red: 1.0, green: 0.48, blue: 0.68, alpha: 1),
            CGColor(red: 0.38, green: 0.72, blue: 1.00, alpha: 1),
        ]
        for i in 0..<4 {
            let angle = CGFloat(i) * (.pi / 2) + CGFloat(t) * 2.2
            let r: CGFloat = 7 + sin(CGFloat(t) * 3 + CGFloat(i)) * 1.5
            let sx = tip.x + cos(angle) * r
            let sy = tip.y + sin(angle) * r * 0.55
            let sz: CGFloat = 1.8 + sin(CGFloat(t) * 4 + CGFloat(i)) * 0.6
            ctx.setFillColor(colors[i])
            ctx.fillEllipse(in: CGRect(x: sx - sz/2, y: sy - sz/2, width: sz, height: sz))
        }
    }

    // MARK: - Alert dot

    private func drawAlertDot(ctx: CGContext) {
        let pulse = (sin(CACurrentMediaTime() * 5) + 1) / 2
        let r: CGFloat = 3.0 + CGFloat(pulse) * 1.0
        ctx.setFillColor(CGColor(red: 0.95, green: 0.20, blue: 0.12, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: bounds.width - r * 2 - 1,
                                   y: bounds.height - r * 2,
                                   width: r * 2, height: r * 2))
    }
}
