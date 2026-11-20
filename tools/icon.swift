// Renders the 1024×1024 app icon PNG: blue→indigo squircle with the SF Symbol used in the menu bar.
// Usage: icon <out.png>
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.24, blue: 0.93, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.56, blue: 1.00, alpha: 1)])!.draw(in: tile, angle: 90)

let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)!
    .withSymbolConfiguration(cfg)!
let s = sym.size
sym.draw(in: NSRect(x: 512 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
