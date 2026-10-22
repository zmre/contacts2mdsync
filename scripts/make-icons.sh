#!/usr/bin/env bash
# Regenerate App/Contacts2MdSync/Assets.xcassets/AppIcon.appiconset from the
# logo PNG. Idempotent: rewrites every icon PNG and Contents.json each run.
#
# Usage: scripts/make-icons.sh [source.png]   (default: assets/contact-sync-logo.png)
#
# Needs only macOS built-ins (Xcode's `swift` via xcrun; CoreGraphics/ImageIO).
#
# Design (macOS icon grid, 1024 canvas):
#   - The logo already has its own silhouette (two overlapping rounded squares
#     on transparency), so it is NOT masked to the system squircle. It is
#     cropped to its opaque bounds and fitted, aspect preserved, inside the
#     824x824 content area (100 px margin per side at 1024), centered.
#   - A soft drop shadow (Apple template-style: down ~1% of size, ~2% blur,
#     ~30% black) is added, scaled per output size.
#   - Every size is rendered straight from the source with high-quality
#     interpolation (only downscaling; the source is ~1368 px of content).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-$root/assets/contact-sync-logo.png}"
out="$root/App/Contacts2MdSync/Assets.xcassets/AppIcon.appiconset"

[[ -f "$src" ]] || { echo "error: source image not found: $src" >&2; exit 1; }
mkdir -p "$out"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/render.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: render <src.png> <outdir>") }
let srcURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let isrc = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let raw = CGImageSourceCreateImageAtIndex(isrc, 0, nil)
else { fail("cannot read \(srcURL.path)") }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

// Normalise to 8-bit premultiplied RGBA so we can scan alpha.
let w = raw.width, h = raw.height
guard let norm = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: w * 4, space: srgb, bitmapInfo: bitmapInfo)
else { fail("cannot allocate context") }
norm.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let px = norm.data?.assumingMemoryBound(to: UInt8.self) else { fail("no pixel data") }

// Opaque bounding box (alpha > ~4%), in top-left-origin pixel rows.
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    let row = px + y * w * 4
    for x in 0..<w where row[x * 4 + 3] > 10 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else { fail("source image is fully transparent") }
guard let full = norm.makeImage(),
      let content = full.cropping(to: CGRect(x: minX, y: minY,
                                             width: maxX - minX + 1, height: maxY - minY + 1))
else { fail("crop failed") }
print("source \(w)x\(h), content \(content.width)x\(content.height) at +\(minX)+\(minY)")

let longest = max(content.width, content.height)
if longest < 824 {
    print("warning: content is \(longest)px; the 512@2x icon upscales it to 824px")
}

func render(_ size: Int, to url: URL) {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: srgb, bitmapInfo: bitmapInfo)
    else { fail("cannot allocate \(size)px context") }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Fit into the 824/1024 content area, centered, aspect preserved.
    let box = s * 824.0 / 1024.0
    let scale = box / CGFloat(longest)
    let dw = CGFloat(content.width) * scale, dh = CGFloat(content.height) * scale
    let rect = CGRect(x: (s - dw) / 2, y: (s - dh) / 2, width: dw, height: dh)

    // Shadow is skipped at tiny sizes where it only muddies the edge.
    if size >= 32 {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
    }
    ctx.draw(content, in: rect)

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot create \(url.path)") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    render(px, to: outDir.appendingPathComponent("icon_\(px).png"))
}
SWIFT

# Run with Xcode's toolchain regardless of any Nix-provided compilers/SDK vars.
env -u SDKROOT -u DEVELOPER_DIR -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS \
    /usr/bin/xcrun swift "$work/render.swift" "$src" "$work"

# Map rendered pixel sizes onto the macOS idiom slots.
entries=()
for pt in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((pt * scale))
        if [[ $scale -eq 1 ]]; then name="icon_${pt}x${pt}.png"; else name="icon_${pt}x${pt}@2x.png"; fi
        cp "$work/icon_${px}.png" "$out/$name"
        entries+=("    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${pt}x${pt}\" }")
    done
done

# Drop any stale PNGs not produced by this run.
find "$out" -maxdepth 1 -name '*.png' ! -name 'icon_*x*.png' -delete

{
    echo '{'
    echo '  "images" : ['
    (IFS=$'\n'; printf '%s\n' "${entries[@]}") | sed '$!s/$/,/'
    echo '  ],'
    echo '  "info" : {'
    echo '    "author" : "xcode",'
    echo '    "version" : 1'
    echo '  }'
    echo '}'
} >"$out/Contents.json"

echo "wrote $(find "$out" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') icons + Contents.json to ${out#"$root"/}"
