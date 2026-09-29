import AppKit
import CoreText

/// 손글씨를 인쇄된 줄에 맞춰 흘려 쓰는 계산.
/// 모든 값은 같은 단위(디자인 단위)로 주고받는다 — 폰트 크기와 폭이 같은 단위면 결과는 배율과 무관하다.
enum RuledText {
    /// 한 줄 폭에 맞게 줄을 나눈다 (CoreText, 한글은 글자 단위로도 끊긴다). 빈 글은 빈 줄 하나.
    static func wrap(_ text: String, fontSize: CGFloat, width: CGFloat) -> [String] {
        guard !text.isEmpty else { return [""] }
        let font = CTFontCreateWithName(Fonts.handName as CFString, fontSize * Fonts.handScale, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(width, 10), height: 1_000_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [text] }
        let ns = text as NSString
        return lines.map { line in
            let r = CTLineGetStringRange(line)
            return ns.substring(with: NSRange(location: r.location, length: r.length))
                .trimmingCharacters(in: .newlines)
        }
    }

    /// 한 줄로 썼을 때의 폭
    static func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName(Fonts.handName as CFString, fontSize * Fonts.handScale, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 한 줄에 다 들어가도록 줄인 비율 (1 이하)
    static func oneLineScale(_ text: String, fontSize: CGFloat, width: CGFloat, minScale: CGFloat = 0.45) -> CGFloat {
        let w = self.width(text, fontSize: fontSize)
        return w <= width ? 1 : max(minScale, width / w)
    }

    /// 글자 한 줄의 자연스러운 높이 (디자인 단위)
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        guard let f = NSFont(name: Fonts.handName, size: fontSize * Fonts.handScale) else { return fontSize * 1.2 }
        return f.ascender - f.descender + f.leading
    }

    struct Layout: Equatable {
        /// 칸(줄) 수. minRows 보다 크면 그만큼 줄 간격을 좁혀 같은 높이에 넣는다.
        var rows: Int
        /// 줄 간격과 글자에 곱할 비율 (= minRows / rows)
        var scale: CGFloat
        /// 항목별로 나뉜 줄
        var lines: [[String]]
        /// 항목별 첫 줄의 칸 번호
        var start: [Int]
        /// 항목들이 쓰고 난 다음 칸 (여기부터 빈 칸)
        var used: Int
    }

    /// items 를 minRows 칸짜리 영역에 차례로 흘려 쓴다.
    /// 긴 항목은 아래 칸을 이어 쓰고, 칸이 모자라면 칸 수를 늘리면서 줄 간격·글자를 같은 비율로 조금씩 줄인다.
    static func layout(_ items: [String], minRows: Int, fontSize: CGFloat, width: CGFloat,
                       minScale: CGFloat = 0.45) -> Layout {
        var rows = minRows
        var result: Layout?
        for _ in 0..<24 {
            let s = CGFloat(minRows) / CGFloat(rows)
            let lines = items.map { wrap($0, fontSize: fontSize * s, width: width) }
            let need = lines.reduce(0) { $0 + $1.count }
            var start: [Int] = []
            var r = 0
            for l in lines { start.append(r); r += l.count }
            result = Layout(rows: max(rows, need), scale: s, lines: lines, start: start, used: need)
            if need <= rows || s <= minScale { break }
            rows = need
        }
        return result!
    }

    /// 한 칸(상자)에 여러 줄로 쓸 때 다 들어가도록 글자를 조금씩 줄인 비율
    static func fitScale(_ text: String, fontSize: CGFloat, width: CGFloat, height: CGFloat,
                         maxLines: Int, minScale: CGFloat = 0.4) -> CGFloat {
        var s: CGFloat = 1
        while s > minScale {
            let n = wrap(text, fontSize: fontSize * s, width: width).count
            if n <= maxLines && CGFloat(n) * lineHeight(fontSize: fontSize * s) <= height { break }
            s *= 0.94
        }
        return max(s, minScale)
    }
}
