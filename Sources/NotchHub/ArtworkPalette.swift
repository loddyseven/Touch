import AppKit

@MainActor enum ArtworkPalette {
    static func accent(_ image: NSImage?) -> NSColor {
        guard let image, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSColor(white: 0.85, alpha: 1) }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size)); return true
        }
        guard rendered else { return NSColor(white: 0.85, alpha: 1) }
        var weights = [Double](repeating: 0, count: 18)
        var red = weights, green = weights, blue = weights
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset+3] > 200 else { continue }
            let r = Double(pixels[offset])/255, g = Double(pixels[offset+1])/255, b = Double(pixels[offset+2])/255
            let high = max(r,g,b), low = min(r,g,b), spread = high-low
            guard high > 0.15, spread > 0.08 else { continue }
            var hue = high == r ? (g-b)/spread : high == g ? 2+(b-r)/spread : 4+(r-g)/spread
            hue = (hue/6 + 1).truncatingRemainder(dividingBy: 1)
            let bucket = min(17, Int(hue * 18)), weight = spread * sqrt(high)
            weights[bucket] += weight; red[bucket] += r*weight; green[bucket] += g*weight; blue[bucket] += b*weight
        }
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0.1 else { return NSColor(white: 0.85, alpha: 1) }
        let selected = NSColor(calibratedRed:red[best]/weights[best],green:green[best]/weights[best],blue:blue[best]/weights[best],alpha:1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        selected.getHue(&h, saturation:&s, brightness:&v, alpha:&a)
        return NSColor(calibratedHue:h,saturation:min(0.72,max(0.3,s)),brightness:max(0.88,v),alpha:1)
    }
}
