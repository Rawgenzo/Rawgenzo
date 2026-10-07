import AppKit

/// 「Rawgenzo について」のパネル。
/// `swift run` で起動したときは Info.plist が無いので、作者などはここから直接渡す。
enum AboutPanel {
    static let authorName = "Yukimitsu IZAWA"
    static let authorEmail = "izawa@izawa.org"
    static let website = URL(string: "https://rawgenzo.github.io")!

    @MainActor
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        func text(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: base) }
        func link(_ s: String, _ url: URL) -> NSAttributedString {
            var a = base
            a[.link] = url
            return NSAttributedString(string: s, attributes: a)
        }

        // 表示: Yukimitsu IZAWA <izawa@izawa.org> / https://rawgenzo.github.io / MIT License
        let credits = NSMutableAttributedString()
        credits.append(text("\(authorName) <"))
        credits.append(link(authorEmail, URL(string: "mailto:\(authorEmail)")!))
        credits.append(text(">\n"))
        credits.append(link(website.absoluteString, website))
        credits.append(text("\nMIT License"))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Rawgenzo",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
