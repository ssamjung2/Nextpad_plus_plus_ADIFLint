// The Map's terrain: Natural Earth's 1:50m shaded relief (public domain), as relief.jpg beside
// the plugin (tools/gen_relief.py made it): 8,192 x 4,096 8-bit grey in plate carrée, -180..180
// and -90..90, 128 where the ground is flat. Drawn twice over the land just filled, read through
// two tables (indexed colour spaces over the same pixels): the shadows (below 128, as 0 to 1, flat ground white) multiplied, darkening the
// slopes away from the light; the lit slopes (above 128, flat ground black) screened, lightening
// those facing it. Flat ground keeps the palette's colour in every palette. The flat maps draw the
// image itself (in bands of latitude for Mercator and Equal Earth, whose rows aren't evenly
// spaced); the globe samples it for each few points of the view, again only when the view moves.

#import "MapView.h"

#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <dlfcn.h>
#include <string>
#include <vector>

namespace {

// The image, read once, and smaller copies of it (each half the last) for the globe zoomed out.
struct Relief {
    struct Level {
        std::vector<uint8_t> px;
        size_t w = 0, h = 0;
    };
    std::vector<Level> levels;  // [0] the full image
    // Over levels[0], as shadows and as light (shadeImages), and each a degree of latitude at a time, north first.
    CGImageRef shadow = nullptr, light = nullptr;
    std::vector<CGImageRef> shadowBands, lightBands;
};

// The grey read as shadows (0 black to 128 and over white) and as light (128 and under black, 255
// white).
void shadeImages(CGDataProviderRef provider, size_t w, size_t h, CGImageRef *shadow, CGImageRef *light) {
    static CGColorSpaceRef shadows = nullptr, lights = nullptr;
    if (!shadows) {
        unsigned char dark[256], lit[256];
        for (int v = 0; v < 256; ++v) {
            dark[v] = (unsigned char)(v >= 128 ? 255 : std::lround(v * 255.0 / 128));
            lit[v] = (unsigned char)(v <= 128 ? 0 : std::lround((v - 128) * 255.0 / 127));
        }
        CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
        shadows = CGColorSpaceCreateIndexed(grey, 255, dark);
        lights = CGColorSpaceCreateIndexed(grey, 255, lit);
        CGColorSpaceRelease(grey);
    }
    *shadow = CGImageCreate(w, h, 8, 8, w, shadows, (CGBitmapInfo)kCGImageAlphaNone, provider, nullptr, true, kCGRenderingIntentDefault);
    *light = CGImageCreate(w, h, 8, 8, w, lights, (CGBitmapInfo)kCGImageAlphaNone, provider, nullptr, true, kCGRenderingIntentDefault);
}

// Shadows multiplied, then light screened, into `rect`.
void drawShade(CGContextRef ctx, CGRect rect, CGImageRef shadow, CGImageRef light, double strength) {
    if (!shadow || !light) return;
    CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
    CGContextSetAlpha(ctx, strength);
    CGContextDrawImage(ctx, rect, shadow);
    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    CGContextSetAlpha(ctx, strength * 0.7);
    CGContextDrawImage(ctx, rect, light);
}

const Relief &relief() {
    static Relief r;
    static bool tried = false;
    if (tried) return r;
    tried = true;
    Dl_info info{};
    if (!dladdr((const void *)&relief, &info) || !info.dli_fname) return r;
    std::string path = info.dli_fname;
    path = path.substr(0, path.find_last_of('/')) + "/relief.jpg";
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path.c_str(), (CFIndex)path.size(), false);
    CGImageSourceRef source = url ? CGImageSourceCreateWithURL(url, nullptr) : nullptr;
    CGImageRef decoded = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (url) CFRelease(url);
    if (source) CFRelease(source);
    if (!decoded) return r;
    Relief::Level full;
    full.w = CGImageGetWidth(decoded), full.h = CGImageGetHeight(decoded);
    if (full.w < 360 || full.h < 180 || full.w != 2 * full.h) {
        CGImageRelease(decoded);
        return r;
    }
    full.px.assign(full.w * full.h, 128);
    CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
    CGContextRef bitmap = CGBitmapContextCreate(full.px.data(), full.w, full.h, 8, full.w, grey, (CGBitmapInfo)kCGImageAlphaNone);
    if (bitmap) {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, full.w, full.h), decoded);
        CGContextRelease(bitmap);
    }
    CGImageRelease(decoded);
    r.levels.push_back(std::move(full));
    while (r.levels.back().w > 1024) {  // each half the last, averaging 2 x 2
        const Relief::Level &big = r.levels.back();
        Relief::Level half;
        half.w = big.w / 2, half.h = big.h / 2;
        half.px.resize(half.w * half.h);
        for (size_t y = 0; y < half.h; ++y)
            for (size_t x = 0; x < half.w; ++x) {
                const uint8_t *a = &big.px[2 * y * big.w + 2 * x], *b = a + big.w;
                half.px[y * half.w + x] = (uint8_t)((a[0] + a[1] + b[0] + b[1] + 2) / 4);
            }
        r.levels.push_back(std::move(half));
    }
    CGColorSpaceRelease(grey);
    const Relief::Level &top = r.levels[0];
    // Static: the data outlives every image made over it.
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, top.px.data(), top.px.size(), nullptr);
    shadeImages(provider, top.w, top.h, &r.shadow, &r.light);
    CGDataProviderRelease(provider);
    if (r.shadow && r.light)
        for (int i = 0; i < 180; ++i) {
            size_t y0 = (size_t)std::lround(i * top.h / 180.0), y1 = (size_t)std::lround((i + 1) * top.h / 180.0);
            CGRect rows = CGRectMake(0, y0, top.w, y1 - y0);
            r.shadowBands.push_back(CGImageCreateWithImageInRect(r.shadow, rows));
            r.lightBands.push_back(CGImageCreateWithImageInRect(r.light, rows));
        }
    return r;
}

// The grey at a point, between the four pixels round it.
double sample(const Relief::Level &l, double lon, double lat) {
    double fx = (lon + 180) / 360 * l.w - 0.5, fy = (90 - lat) / 180 * l.h - 0.5;
    double x0 = std::floor(fx), y0 = std::floor(fy), tx = fx - x0, ty = fy - y0;
    auto at = [&](double x, double y) {
        long xi = ((long)x % (long)l.w + (long)l.w) % (long)l.w;  // round the world east and west
        long yi = std::clamp((long)y, 0L, (long)l.h - 1);
        return (double)l.px[(size_t)yi * l.w + (size_t)xi];
    };
    return (at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx) * (1 - ty) + (at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx) * ty;
}

}  // namespace

// The globe's terrain as last drawn, and the view it was drawn for.
struct ReliefShown {
    std::vector<uint8_t> px;
    size_t w = 0, h = 0;
    CGRect rect = CGRectNull;  // on the plane
    std::array<double, 7> view{};
};

@implementation ADIFMapView (Relief)

- (void)drawRelief:(CGContextRef)ctx land:(CGPathRef)land {
    if (_style.terrain <= 0 || !land) return;
    // Zoomed in past the relief's own detail (some 23 pixels a degree), it fades out.
    double fade = std::clamp((48 - _zoom) / (48 - 16), 0.0, 1.0);
    if (fade <= 0) return;
    const Relief &r = relief();
    if (!r.shadow || !r.light) return;
    NSRect b = self.bounds;
    double ppu = [self ppu];
    CGRect view = CGRectMake(_cx - b.size.width / 2 / ppu, _cy - b.size.height / 2 / ppu, b.size.width / ppu, b.size.height / ppu);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, land);
    CGContextEOClip(ctx);
    double strength = (_style.terrain >= 2 ? 0.9 : 0.5) * fade;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    switch (_pr.kind()) {
        case adif::Projection::Equirectangular: drawShade(ctx, CGRectMake(-180, -90, 360, 180), r.shadow, r.light, strength); break;
        case adif::Projection::Mercator:
        case adif::Projection::EqualEarth:
            for (size_t i = 0; i < r.shadowBands.size(); ++i) {  // each degree of latitude as wide as the map is half-way down it
                double north = 90.0 - i, south = north - 1, x, top, bottom, edge, y;
                if (_pr.kind() == adif::Projection::Mercator && north > 85.1) continue;  // past its limit, where it stops
                _pr.forward(0, north, &x, &top);
                _pr.forward(0, south, &x, &bottom);
                _pr.forward(180, north - 0.5, &edge, &y);
                CGRect band = CGRectMake(-edge, bottom, 2 * edge, top - bottom);
                if (band.size.height <= 1e-9 || !CGRectIntersectsRect(band, view)) continue;
                drawShade(ctx, band, r.shadowBands[i], r.lightBands[i], strength);
            }
            break;
        case adif::Projection::Globe: {
            CGRect rect = CGRectIntersection(view, CGRectMake(-180 / M_PI, -180 / M_PI, 360 / M_PI, 360 / M_PI));  // the disc's box
            if (CGRectIsEmpty(rect)) break;
            std::array<double, 7> key{_pr.centerLat(), _pr.centerLon(), rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, ppu};
            if (!_reliefShown) _reliefShown = std::make_shared<ReliefShown>();
            ReliefShown &shown = *_reliefShown;
            if (shown.view != key || shown.px.empty()) {
                // A sample every point or so, fewer in a big window; from the copy whose pixels are
                // about as far apart as the samples, so the zoomed-out globe isn't grainy.
                double pixels = rect.size.width * ppu * rect.size.height * ppu;
                double step = std::max(1.0, std::sqrt(pixels / 600000));
                shown.w = (size_t)std::max(1.0, std::ceil(rect.size.width * ppu / step));
                shown.h = (size_t)std::max(1.0, std::ceil(rect.size.height * ppu / step));
                double perDegree = ppu / step;  // samples a degree, at the centre
                size_t level = 0;
                while (level + 1 < r.levels.size() && r.levels[level + 1].w / 360.0 >= perDegree) ++level;
                const Relief::Level &l = r.levels[level];
                shown.px.assign(shown.w * shown.h, 128);
                for (size_t yy = 0; yy < shown.h; ++yy)
                    for (size_t xx = 0; xx < shown.w; ++xx) {
                        double px = rect.origin.x + (xx + 0.5) * rect.size.width / shown.w;
                        double py = CGRectGetMaxY(rect) - (yy + 0.5) * rect.size.height / shown.h;  // row 0 at the top
                        double lon, lat;
                        if (_pr.inverse(px, py, &lon, &lat)) shown.px[yy * shown.w + xx] = (uint8_t)std::lround(sample(l, lon, lat));
                    }
                shown.rect = rect, shown.view = key;
            }
            CFDataRef bytes = CFDataCreate(nullptr, shown.px.data(), (CFIndex)shown.px.size());  // its own copy, however long the images live
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes);
            CFRelease(bytes);
            CGImageRef shadow = nullptr, light = nullptr;
            shadeImages(provider, shown.w, shown.h, &shadow, &light);
            drawShade(ctx, shown.rect, shadow, light, strength);
            CGImageRelease(shadow);
            CGImageRelease(light);
            CGDataProviderRelease(provider);
            break;
        }
    }
    CGContextRestoreGState(ctx);
}

@end
