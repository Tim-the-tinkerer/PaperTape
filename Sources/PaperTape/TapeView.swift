import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a classic 1-inch 8-channel punched paper tape strip.
///
/// Drawing is entirely Canvas-based (no per-column SwiftUI views) so large
/// tapes cannot exhaust AttributeGraph. Only a capped window of columns is drawn.
struct TapeStripView: View {
    let document: TapeEngine.TapeDocument
    var columnWidth: CGFloat = 18
    var showLegend: Bool = true
    var highlightIndex: Int? = nil
    /// Hard cap on columns drawn in the UI (full document still held for save/export).
    var maxDisplayColumns: Int = 1_024

    private let channelSpacing: CGFloat = 14
    private let marginY: CGFloat = 12
    private let edgePad: CGFloat = 20
    private let legendHeight: CGFloat = 18

    /// Visual channel order top → bottom: 8…4, feed, 3…1
    private static let legacyRows: [RowKind] = [
        .channel(8), .channel(7), .channel(6), .channel(5), .channel(4),
        .feed,
        .channel(3), .channel(2), .channel(1),
    ]

    private var visualRows: [RowKind] {
        document.packing == .base512 ? [.channel(9)] + Self.legacyRows : Self.legacyRows
    }

    private enum RowKind {
        case channel(Int)
        case feed
    }

    private var displayColumns: [TapeEngine.Column] {
        if document.columns.count <= maxDisplayColumns {
            return document.columns
        }
        return Array(document.columns.prefix(maxDisplayColumns))
    }

    private var isTruncated: Bool {
        document.columns.count > maxDisplayColumns
    }

    private var tapeHeight: CGFloat {
        marginY * 2 + CGFloat(visualRows.count) * channelSpacing
    }

    private var totalHeight: CGFloat {
        tapeHeight + (showLegend ? legendHeight + 4 : 0)
    }

    private var contentWidth: CGFloat {
        let n = max(displayColumns.count, 1)
        return max(edgePad * 2 + CGFloat(n) * columnWidth, 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isTruncated {
                Text("Showing first \(maxDisplayColumns.formatted()) of \(document.columns.count.formatted()) columns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                canvas
                    .frame(width: contentWidth, height: totalHeight)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.vertical, 4)
            }
        }
    }

    private var canvas: some View {
        // Snapshot for the Canvas closure — avoid capturing `self` document wholesale on every draw.
        let cols = displayColumns
        let colW = columnWidth
        let pad = edgePad
        let mY = marginY
        let chSpace = channelSpacing
        let tH = tapeHeight
        let showLeg = showLegend
        let hi = highlightIndex
        let paper = paperColor
        let rows = visualRows

        return Canvas { context, size in
            let paperRect = CGRect(x: 0, y: 0, width: size.width, height: tH)
            context.fill(
                Path(roundedRect: paperRect, cornerRadius: 4),
                with: .color(paper)
            )

            // Edge wear
            var topEdge = Path()
            topEdge.move(to: CGPoint(x: 0, y: 1))
            topEdge.addLine(to: CGPoint(x: size.width, y: 1))
            context.stroke(topEdge, with: .color(.white.opacity(0.35)), lineWidth: 1)

            var bottomEdge = Path()
            bottomEdge.move(to: CGPoint(x: 0, y: tH - 1))
            bottomEdge.addLine(to: CGPoint(x: size.width, y: tH - 1))
            context.stroke(bottomEdge, with: .color(.black.opacity(0.12)), lineWidth: 1)

            // Perforated leaders
            for side in [pad * 0.25, size.width - pad * 0.25] {
                var y: CGFloat = 4
                while y < tH {
                    let r = CGRect(x: side - 1.2, y: y, width: 2.4, height: 2.4)
                    context.fill(Path(ellipseIn: r), with: .color(.black.opacity(0.08)))
                    y += 8
                }
            }

            // Feed track
            if let feedIdx = rows.firstIndex(where: {
                if case .feed = $0 { return true }
                return false
            }) {
                let y = mY + CGFloat(feedIdx) * chSpace + chSpace * 0.5
                var track = Path()
                track.move(to: CGPoint(x: pad * 0.4, y: y))
                track.addLine(to: CGPoint(x: size.width - pad * 0.4, y: y))
                context.stroke(track, with: .color(.black.opacity(0.05)), lineWidth: 3)
            }

            if cols.isEmpty {
                let text = Text("Empty tape — type or open data to punch columns")
                context.draw(text, at: CGPoint(x: size.width / 2, y: tH / 2), anchor: .center)
            } else {
                for (index, col) in cols.enumerated() {
                    let x = pad + CGFloat(index) * colW + colW * 0.5

                    if hi == col.id {
                        let hiRect = CGRect(
                            x: x - colW * 0.45,
                            y: 2,
                            width: colW * 0.9,
                            height: tH - 4
                        )
                        context.fill(
                            Path(roundedRect: hiRect, cornerRadius: 3),
                            with: .color(AppTheme.accent.opacity(0.15))
                        )
                    }

                    for (rowIndex, row) in rows.enumerated() {
                        let y = mY + CGFloat(rowIndex) * chSpace + chSpace * 0.5
                        switch row {
                        case .feed:
                            Self.drawHole(
                                context: context,
                                center: CGPoint(x: x, y: y),
                                radius: 2.4,
                                level: 2,
                                isSprocket: true
                            )
                        case .channel(let n):
                            if col.isBase256 {
                                Self.drawGrayscaleHole(
                                    context: context,
                                    center: CGPoint(x: x, y: y),
                                    radius: 3.2,
                                    intensity: col.base256Bytes[n - 1]
                                )
                            } else {
                                Self.drawHole(
                                    context: context,
                                    center: CGPoint(x: x, y: y),
                                    radius: 3.2,
                                    level: col.channelLevel(n - 1),
                                    isSprocket: false
                                )
                            }
                        }
                    }

                    if showLeg {
                        let label: String
                        if col.isBase512 {
                            label = String(col.base512Value)
                        } else if let c = col.printableChar {
                            label = String(c)
                        } else {
                            label = "·"
                        }
                        let legendY = tH + 10
                        let text = Text(label)
                            .font(.system(size: max(9, colW * 0.55), design: .monospaced))
                            .foregroundColor(
                                col.printableChar != nil
                                    ? AppTheme.ink
                                    : Color.secondary.opacity(0.45)
                            )
                        context.draw(text, at: CGPoint(x: x, y: legendY), anchor: .center)
                    }
                }
            }
        }
    }

    private var paperColor: Color {
        Color(red: 0.93, green: 0.88, blue: 0.74)
    }

    /// Continuous grayscale hole for v8 base-256 (intensity = channel byte 0…255).
    private static func drawGrayscaleHole(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        intensity: UInt8
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let t = CGFloat(intensity) / 255.0
        context.stroke(
            Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
            with: .color(Color.black.opacity(0.10 + 0.12 * t)),
            lineWidth: 0.6
        )
        guard intensity > 0 else { return }
        let fillR = radius * (0.35 + 0.65 * t)
        let fillRect = CGRect(
            x: center.x - fillR,
            y: center.y - fillR,
            width: fillR * 2,
            height: fillR * 2
        )
        context.fill(
            Path(ellipseIn: fillRect),
            with: .color(Color.black.opacity(0.12 + 0.66 * t))
        )
    }

    /// Draw a discrete multilevel hole (v1–v7). Levels 0…7.
    private static func drawHole(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        level: UInt8,
        isSprocket: Bool
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        if level == 0 {
            context.stroke(
                Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
                with: .color(Color.black.opacity(0.10)),
                lineWidth: 0.7
            )
            return
        }
        // Map 1…7 → fill radius fraction (calibrated multilevel depths).
        let fractions: [CGFloat] = [0, 0.28, 0.38, 0.48, 0.58, 0.68, 0.80, 1.0]
        let idx = min(Int(level), fractions.count - 1)
        let frac = fractions[idx]
        if frac >= 0.98 {
            context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.78)))
            let inner = rect.insetBy(dx: radius * 0.35, dy: radius * 0.35)
            context.stroke(
                Path(ellipseIn: inner),
                with: .color(Color.white.opacity(isSprocket ? 0.08 : 0.06)),
                lineWidth: 0.6
            )
            return
        }
        let midR = radius * frac
        let midRect = CGRect(
            x: center.x - midR,
            y: center.y - midR,
            width: midR * 2,
            height: midR * 2
        )
        context.stroke(
            Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
            with: .color(Color.black.opacity(0.12)),
            lineWidth: 0.6
        )
        let opacity = 0.35 + 0.06 * CGFloat(idx)
        context.fill(Path(ellipseIn: midRect), with: .color(Color.black.opacity(opacity)))
    }
}

/// Channel legend labels shown beside the tape.
struct TapeChannelLegend: View {
    var nineChannels = false
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if nineChannels { Text("ch9").frame(height: 14) }
            Text("ch8").frame(height: 14)
            Text("ch7").frame(height: 14)
            Text("ch6").frame(height: 14)
            Text("ch5").frame(height: 14)
            Text("ch4").frame(height: 14)
            Text("feed")
                .frame(height: 14)
                .foregroundStyle(AppTheme.accent)
            Text("ch3").frame(height: 14)
            Text("ch2").frame(height: 14)
            Text("ch1").frame(height: 14)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.top, 12)
    }
}

/// Export the visual tape as a PNG for sharing or printing.
enum TapeImageExporter {
    static func renderPNG(
        document: TapeEngine.TapeDocument,
        columnWidth: CGFloat = 16,
        maxColumns: Int = 512
    ) -> Data? {
        let cols = Array(document.columns.prefix(maxColumns))
        let limited = TapeEngine.TapeDocument(
            columns: cols.enumerated().map { index, column in
                var copy = column
                copy.id = index
                return copy
            },
            originalName: document.originalName,
            originalSize: document.originalSize,
            compression: document.compression,
            transferEncoding: document.transferEncoding,
            note: document.note,
            blockSize: document.blockSize,
            integrity: nil
        )

        let edgePad: CGFloat = 24
        let marginY: CGFloat = 16
        let channelSpacing: CGFloat = 16
        let nineChannels = document.packing == .base512
        let rows = nineChannels ? 10 : 9
        let legendH: CGFloat = 22
        let headerH: CGFloat = 28
        let width = max(edgePad * 2 + CGFloat(max(cols.count, 1)) * columnWidth, 320)
        let tapeH = marginY * 2 + CGFloat(rows) * channelSpacing
        let height = headerH + tapeH + legendH + 16

        // Guard absurd bitmap sizes
        guard width <= 16_384, height <= 4_096 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.15, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let headerNote: String
        if document.columns.count > maxColumns {
            headerNote = "PaperTape · \(limited.originalName) · first \(limited.columns.count) of \(document.columns.count)"
        } else {
            headerNote = "PaperTape · \(limited.originalName) · \(limited.columns.count) columns"
        }
        drawText(
            in: ctx,
            headerNote,
            at: CGPoint(x: 16, y: 8),
            size: 11,
            color: NSColor(srgbRed: 0.85, green: 0.80, blue: 0.68, alpha: 1)
        )

        let tapeY = headerH
        let paperColor = CGColor(srgbRed: 0.93, green: 0.88, blue: 0.74, alpha: 1)
        ctx.setFillColor(paperColor)
        let paperRect = CGRect(x: 8, y: tapeY, width: width - 16, height: tapeH)
        let paperPath = CGPath(roundedRect: paperRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(paperPath)
        ctx.fillPath()

        let visualChannels: [Int?] = (nineChannels ? [9] : []) + [8, 7, 6, 5, 4, nil, 3, 2, 1]

        for col in limited.columns {
            let x = edgePad + CGFloat(col.id) * columnWidth + columnWidth * 0.5
            for (rowIndex, ch) in visualChannels.enumerated() {
                let y = tapeY + marginY + CGFloat(rowIndex) * channelSpacing + channelSpacing * 0.5
                if let ch {
                    drawExportHole(ctx: ctx, cx: x, cy: y, r: 3.4, punched: col.holes[ch - 1], sprocket: false)
                } else {
                    drawExportHole(ctx: ctx, cx: x, cy: y, r: 2.5, punched: true, sprocket: true)
                }
            }
        }

        let legendY = tapeY + tapeH + 4
        for col in limited.columns {
            let x = edgePad + CGFloat(col.id) * columnWidth + columnWidth * 0.5
            let label: String
            if nineChannels {
                label = String(col.base512Value)
            } else if let c = col.printableChar {
                label = String(c)
            } else {
                label = "·"
            }
            drawTextCentered(
                in: ctx,
                label,
                at: CGPoint(x: x, y: legendY),
                size: 9,
                color: NSColor(srgbRed: 0.75, green: 0.72, blue: 0.62, alpha: 1)
            )
        }

        guard let image = ctx.makeImage() else { return nil }
        return pngData(from: image)
    }

    private static func drawExportHole(ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, punched: Bool, sprocket: Bool) {
        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        if punched {
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.07, blue: 0.06, alpha: 0.85))
            ctx.fillEllipse(in: rect)
        } else {
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12))
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.4, dy: 0.4))
        }
        _ = sprocket
    }

    private static func drawText(in ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        let attr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x, y: -point.y - size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawTextCentered(in ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        let attr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x - bounds.width / 2, y: -point.y - size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func pngData(from image: CGImage) -> Data? {
        let mut = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mut,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mut as Data
    }
}
