import CoreGraphics
import Foundation

/// ソニーのメーカー独自の欄(EXIF の MakerNote。ImageIO では取れない)から、撮影時の情報を読む
enum SonyMakerNote {
    /// FocusLocation(タグ 0x2027。int16u × 4: 画像の幅・高さ・ピントの x・y)。カメラの記録の向き(横長)に対する比率で返す。
    /// α7S III では、ゾーン AF・顔の追尾のどちらでも、ピントを合わせた 1 点が入っていた(AF の枠の大きさは入っていない)
    static func focusPoint(url: URL) -> CGPoint? {
        guard let tiff = TIFFReader(url: url), let ifd0 = tiff.firstIFDOffset,
              let entries0 = tiff.entries(atIFD: ifd0),
              let exifPointer = entries0.first(where: { $0.tag == 0x8769 }).flatMap({ tiff.integers($0)?.first }),
              let exif = tiff.entries(atIFD: exifPointer),
              let note = exif.first(where: { $0.tag == 0x927c }),
              let start = tiff.valueOffset(note, size: 1) else { return nil }
        // 見出し "SONY DSC \0\0\0"(12 バイト)の後に IFD が続く。オフセットはファイルの先頭から
        let header = tiff.bytes(at: start, count: 4).map { String(decoding: $0, as: UTF8.self) }
        let ifd = header == "SONY" ? start + 12 : start
        guard let entries = tiff.entries(atIFD: ifd),
              let loc = entries.first(where: { $0.tag == 0x2027 }).flatMap({ tiff.integers($0) }),
              loc.count == 4, loc[0] > 0, loc[1] > 0 else { return nil }
        let (w, h, x, y) = (Double(loc[0]), Double(loc[1]), Double(loc[2]), Double(loc[3]))
        // 0,0 はピント位置が記録されていない(マニュアルフォーカスなど)とみなす
        guard x > 0 || y > 0, x <= w, y <= h else { return nil }
        return CGPoint(x: x / w, y: y / h)
    }
}
