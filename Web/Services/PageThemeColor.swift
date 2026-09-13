import AppKit

/// Page color stays on its Tab; only the user's matching preference is persisted.
enum PageThemeColor {
    static func color(from value: Any?) -> NSColor? {
        let components: [Int]?
        if let result = value as? [String: Any] {
            var votes: [[Int]: Int] = [:]
            for sample in (result["edges"] as? [Any] ?? []).prefix(5) {
                if let color = channels(from: sample) { votes[color, default: 0] += 1 }
            }
            // Three of five top-edge samples must agree. A single control or image
            // cannot set the frame color; ambiguous surfaces use the page fallback.
            components = votes.first(where: { $0.value >= 3 })?.key
                ?? channels(from: result["fallback"])
        } else {
            components = channels(from: value)
        }
        guard let components else { return nil }
        return NSColor(srgbRed: CGFloat(components[0]) / 255, green: CGFloat(components[1]) / 255,
                       blue: CGFloat(components[2]) / 255, alpha: 1)
    }

    private static func channels(from pixels: Any?) -> [Int]? {
        guard let values = pixels as? [NSNumber], values.count == 4 else { return nil }
        let components = values.map(\.doubleValue)
        guard components.allSatisfy({ $0.isFinite && (0...255).contains($0) && $0.rounded() == $0 }),
              components[3] == 255 else { return nil }
        return components.map(Int.init)
    }

    static func usable(_ color: NSColor?) -> NSColor? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              rgb.alphaComponent == 1 else { return nil }
        return rgb
    }

    // Read in WebKit's isolated content world. The one-pixel canvas is detached;
    // no page element, style, color scheme, storage or network request is changed.
    static let script = """
        (() => {
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 1;
            const context = canvas.getContext('2d', { colorSpace: 'srgb', willReadFrequently: true });
            if (!context) return null;
            const sample = value => {
                if (!value || value.length > 256 || !CSS.supports('color', value)) return null;
                if (/^(currentcolor|inherit|initial|unset|revert|revert-layer)$/i.test(value.trim())) return null;
                context.fillStyle = '#010203';
                context.fillStyle = value;
                const parsed = context.fillStyle;
                context.fillStyle = '#040506';
                context.fillStyle = value;
                if (context.fillStyle !== parsed) return null;
                context.clearRect(0, 0, 1, 1);
                context.fillRect(0, 0, 1, 1);
                const rgba = Array.from(context.getImageData(0, 0, 1, 1).data);
                return rgba[3] === 255 ? rgba : null;
            };
            const width = window.innerWidth;
            const height = window.innerHeight;
            const edgeColor = fraction => {
                if (!Number.isFinite(width) || !Number.isFinite(height) || width < 2 || height < 2) return null;
                const x = Math.min(width - 1, Math.max(1, width * fraction));
                const y = Math.min(8, height - 1);
                let element = document.elementFromPoint(x, y);
                let color = null;
                for (let depth = 0; element && depth < 16; depth++, element = element.parentElement) {
                    const style = getComputedStyle(element);
                    if (Number(style.opacity) !== 1 || style.filter !== 'none' || style.mixBlendMode !== 'normal') return null;
                    if (!color) {
                        if (['IMG', 'VIDEO', 'CANVAS', 'SVG', 'IFRAME', 'OBJECT', 'EMBED'].includes(element.tagName.toUpperCase())) return null;
                        if (style.backgroundImage !== 'none' || (style.maskImage && style.maskImage !== 'none')) return null;
                        const rect = element.getBoundingClientRect();
                        if (element !== document.body && element !== document.documentElement &&
                            Number.isFinite(rect.width) && Number.isFinite(rect.height) &&
                            rect.width >= width * 0.6 && rect.height >= 24 && rect.top <= y && rect.bottom > y) {
                            color = sample(style.backgroundColor);
                        }
                    }
                    if (element === document.documentElement) return color;
                }
                return null;
            };
            const edges = [0.1, 0.3, 0.5, 0.7, 0.9].map(edgeColor);
            const fallback = () => {
                for (const meta of Array.from(document.querySelectorAll('meta[name="theme-color"]')).slice(0, 16)) {
                    if (meta.media && !matchMedia(meta.media).matches) continue;
                    const color = sample(meta.content);
                    if (color) return color;
                }
                for (const element of [document.body, document.documentElement]) {
                    if (!element) continue;
                    const color = sample(getComputedStyle(element).backgroundColor);
                    if (color) return color;
                }
                return null;
            };
            return { edges, fallback: fallback() };
        })()
        """
}
