#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText

/// 손글씨를 인쇄된 줄에 맞춰 흘려 쓰는 계산.
/// 모든 값은 같은 단위(디자인 단위)로 주고받는다 — 폰트 크기와 폭이 같은 단위면 결과는 배율과 무관하다.
public enum RuledText {
    /// 한 줄 폭에 맞게 줄을 나눈다 (CoreText, 한글은 글자 단위로도 끊긴다). 빈 글은 빈 줄 하나.
    public static func wrap(_ text: String, fontSize: CGFloat, width: CGFloat) -> [String] {
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

    /// wrap 과 같게 나눈 줄마다 글 안의 자리 (NSString 단위). 빈 글은 빈 줄 하나.
    /// 쓰는 중에 ↑ ↓ 로 줄을 옮길 때, 글자 커서가 첫 줄 / 마지막 줄에 있는지 볼 때 쓴다.
    public static func lineRanges(_ text: String, fontSize: CGFloat, width: CGFloat) -> [NSRange] {
        guard !text.isEmpty else { return [NSRange(location: 0, length: 0)] }
        let font = CTFontCreateWithName(Fonts.handName as CFString, fontSize * Fonts.handScale, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(width, 10), height: 1_000_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else {
            return [NSRange(location: 0, length: (text as NSString).length)]
        }
        return lines.map { let r = CTLineGetStringRange($0); return NSRange(location: r.location, length: r.length) }
    }

    /// 한 줄로 썼을 때의 폭
    public static func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName(Fonts.handName as CFString, fontSize * Fonts.handScale, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 한 줄에 다 들어가도록 줄인 비율 (1 이하)
    public static func oneLineScale(_ text: String, fontSize: CGFloat, width: CGFloat, minScale: CGFloat = 0.45) -> CGFloat {
        let w = self.width(text, fontSize: fontSize)
        return w <= width ? 1 : max(minScale, width / w)
    }

    /// 글자 한 줄의 자연스러운 높이 (디자인 단위)
    public static func lineHeight(fontSize: CGFloat) -> CGFloat {
        guard let f = PlatformFont(name: Fonts.handName, size: fontSize * Fonts.handScale) else { return fontSize * 1.2 }
        return f.ascender - f.descender + f.leading
    }

    public struct Layout: Equatable {
        /// 칸(줄) 수. minRows 보다 크면 그만큼 줄 간격을 좁혀 같은 높이에 넣는다.
        public var rows: Int
        /// 줄 간격과 글자에 곱할 비율 (= minRows / rows)
        public var scale: CGFloat
        /// 항목별로 나뉜 줄
        public var lines: [[String]]
        /// 항목별 첫 줄의 칸 번호
        public var start: [Int]
        /// 항목들이 쓰고 난 다음 칸 (여기부터 빈 칸)
        public var used: Int
    }

    /// items 를 minRows 칸짜리 영역에 차례로 흘려 쓴다.
    /// 긴 항목은 아래 칸을 이어 쓰고, 칸이 모자라면 칸 수를 늘리면서 줄 간격·글자를 같은 비율로 조금씩 줄인다.
    public static func layout(_ items: [String], minRows: Int, fontSize: CGFloat, width: CGFloat,
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

    /// 줄을 정해 쓴 항목들 (1.0.5 할 일)
    public struct RowLayout: Equatable {
        public struct Item: Equatable {
            /// 쓰기 시작한 줄
            public var row: Int
            /// 줄마다 나뉜 글 (쓰는 줄 수 = lines.count)
            public var lines: [String]
            /// 막혀서 줄인 글자 비율 (1 = 그대로). 줄 간격은 그대로 두고 글자만 줄인다.
            public var fit: CGFloat
            public var span: Int { lines.count }
        }

        /// 칸(줄) 수. minRows 보다 크면 그만큼 줄 간격을 좁혀 같은 높이에 넣는다.
        public var rows: Int
        /// 줄 간격과 글자에 곱할 비율 (= minRows / rows)
        public var scale: CGFloat
        /// 항목마다 (넘겨준 순서 그대로)
        public var items: [Item]
        /// 줄마다 그 줄에 쓴 항목 번호 (빈 줄은 nil). 긴 항목이 이어 쓴 줄도 그 항목의 것이다.
        public var owners: [Int?]

        public func owner(_ row: Int) -> Int? { owners.indices.contains(row) ? owners[row] : nil }
        public func isEmpty(_ row: Int) -> Bool { owners.indices.contains(row) && owners[row] == nil }
        public var emptyRows: [Int] { owners.indices.filter { owners[$0] == nil } }
    }

    /// 줄 번호를 정해 쓴 항목들을 놓는다. items 는 줄 번호가 커지는 순서 (겹치지 않게).
    /// 항목은 제 줄에서 시작해 아래 줄이 비어 있는 동안만 이어 쓰고, 다음 항목(또는 마지막 줄)에 막히면
    /// 가진 줄에 다 들어가도록 글자를 줄인다 (fitScale). 칸 수는 minRows 이고, 줄 번호가 그보다 크면
    /// 그 줄까지 칸을 늘리면서 줄 간격·글자를 같은 비율로 줄인다 (layout 과 같다).
    public static func rowLayout(_ items: [(row: Int, text: String)], minRows: Int, fontSize: CGFloat, width: CGFloat,
                          minFit: CGFloat = 0.4) -> RowLayout {
        let rows = max(minRows, (items.map(\.row).max() ?? -1) + 1)
        let s = CGFloat(minRows) / CGFloat(rows)
        let fs = fontSize * s
        var owners = [Int?](repeating: nil, count: rows)
        var out: [RowLayout.Item] = []
        for (k, it) in items.enumerated() {
            let r = min(max(it.row, 0), rows - 1)
            let limit = k + 1 < items.count ? min(max(items[k + 1].row, r + 1), rows) : rows
            let avail = max(1, limit - r)
            var fit: CGFloat = 1
            var lines = wrap(it.text, fontSize: fs, width: width)
            if lines.count > avail {
                fit = fitScale(it.text, fontSize: fs, width: width, height: .greatestFiniteMagnitude,
                               maxLines: avail, minScale: minFit)
                lines = wrap(it.text, fontSize: fs * fit, width: width)
                // 가장 작게 줄여도 넘치면 남은 줄에 담고 끝에 … (글은 그대로 있다)
                if lines.count > avail {
                    lines = Array(lines.prefix(avail))
                    lines[avail - 1] += "…"
                }
            }
            for j in r..<min(r + lines.count, rows) where owners[j] == nil { owners[j] = k }
            out.append(RowLayout.Item(row: r, lines: lines, fit: fit))
        }
        return RowLayout(rows: rows, scale: s, items: out, owners: owners)
    }

    /// 한 칸(상자)에 여러 줄로 쓸 때 다 들어가도록 글자를 조금씩 줄인 비율
    public static func fitScale(_ text: String, fontSize: CGFloat, width: CGFloat, height: CGFloat,
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
