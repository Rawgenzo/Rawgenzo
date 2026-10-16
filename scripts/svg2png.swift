// docs/images の図(SVG)を、WebKit(Safari と同じ描画)で 2 倍の解像度の PNG にする。
// GitHub の文書には PNG を貼り、SVG は編集用の元として残す。
//
//   swiftc -O -o /tmp/svg2png scripts/svg2png.swift
//   /tmp/svg2png docs/images/ai-mcp-overview.svg docs/images/ai-mcp-overview.png
//
// 大きさは SVG の width / height 属性から読む。日本語は macOS のヒラギノで描かれる
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("使い方: svg2png <入力.svg> <出力.png>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1]).standardizedFileURL
let output = URL(fileURLWithPath: args[2])
let scale = 2.0

/// SVG の width / height 属性(ポイント)
func svgSize(_ url: URL) -> (Double, Double)? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let head = text.range(of: "<svg[^>]*>", options: .regularExpression).map({ String(text[$0]) }) else { return nil }
    func attr(_ name: String) -> Double? {
        guard let r = head.range(of: "\(name)=\"[0-9.]+\"", options: .regularExpression) else { return nil }
        return Double(head[r].dropFirst(name.count + 2).dropLast())
    }
    guard let w = attr("width"), let h = attr("height") else { return nil }
    return (w, h)
}

guard let (width, height) = svgSize(input) else {
    FileHandle.standardError.write("SVG の width / height が読めません: \(input.path)\n".data(using: .utf8)!)
    exit(1)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let width: Double, height: Double, scale: Double
    let output: URL
    let web: WKWebView

    init(width: Double, height: Double, scale: Double, output: URL) {
        self.width = width; self.height = height; self.scale = scale; self.output = output
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // フォントの読み込みを少し待つ
        let (width, height, scale, output) = (self.width, self.height, self.scale, self.output)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: width, height: height)
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    FileHandle.standardError.write("描けません: \(String(describing: error))\n".data(using: .utf8)!)
                    exit(1)
                }
                // 画面の倍率(Retina)によらず、ちょうど scale 倍のピクセル数に描き直す
                let pw = Int(width * scale), ph = Int(height * scale)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: width, height: height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: output) } catch {
                    FileHandle.standardError.write("書けません: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
                print("\(output.lastPathComponent): \(pw)×\(ph)")
                exit(0)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("読めません: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(width: width, height: height, scale: scale, output: output)
// SVG ファイルそのものを読ませる(HTML から img で参照すると、ファイルを読む権限が無く表示されない)
renderer.web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write("時間切れ\n".data(using: .utf8)!)
    exit(1)
}
app.run()
