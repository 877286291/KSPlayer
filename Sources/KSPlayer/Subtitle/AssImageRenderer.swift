//
//  AssImageRenderer.swift
//  KSPlayer
//
//  libass-backed ASS/SSA renderer: full styles, transforms, karaoke, etc.
//

import CoreGraphics
import Foundation
import libass

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Renders ASS/SSA events to `UIImage` via libass.
///
/// Incomplete libass handle types are imported as `OpaquePointer`.
final class AssImageRenderer {
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private let lock = NSLock()
    private var frameWidth = 1920
    private var frameHeight = 1080
    private var videoSizeSet = false
    private var readOrder: Int32 = 0
    private var cachedImage: UIImage?

    init?(fontsDirectory: String?, defaultFontPath: String?) {
        guard let library = ass_library_init() else { return nil }
        self.library = library
        ass_set_extract_fonts(library, 1)
        if let fontsDirectory {
            fontsDirectory.withCString { ass_set_fonts_dir(library, $0) }
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            self.library = nil
            return nil
        }
        self.renderer = renderer
        guard let track = ass_new_track(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            self.renderer = nil
            self.library = nil
            return nil
        }
        self.track = track
        configureFonts(defaultFontPath: defaultFontPath)
        applyFrameSize()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if let track {
            ass_free_track(track)
            self.track = nil
        }
        if let renderer {
            ass_renderer_done(renderer)
            self.renderer = nil
        }
        if let library {
            ass_library_done(library)
            self.library = nil
        }
        cachedImage = nil
    }

    /// Feed Matroska CodecPrivate / script header.
    func setCodecPrivate(_ data: UnsafePointer<UInt8>, size: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let track, size > 0 else { return }
        var bytes = [Int8](repeating: 0, count: size)
        memcpy(&bytes, data, size)
        bytes.withUnsafeMutableBufferPointer { buf in
            ass_process_codec_private(track, buf.baseAddress, Int32(size))
        }
        if let header = String(bytes: UnsafeBufferPointer(start: data, count: size), encoding: .utf8)
            ?? String(bytes: UnsafeBufferPointer(start: data, count: size), encoding: .isoLatin1)
        {
            applyPlayRes(from: header)
        }
        cachedImage = nil
    }

    /// Prefer video pixel size for storage/frame when known.
    func setVideoSize(_ size: CGSize) {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        frameWidth = w
        frameHeight = h
        videoSizeSet = true
        applyFrameSize()
        cachedImage = nil
    }

    func processChunk(_ event: String, startMS: Int64, durationMS: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let track else { return }
        let chunk = Self.matroskaChunk(from: event, readOrder: &readOrder)
        guard !chunk.isEmpty else { return }
        var bytes = Array(chunk.utf8CString)
        let size = max(0, bytes.count - 1)
        bytes.withUnsafeMutableBufferPointer { buf in
            ass_process_chunk(track, buf.baseAddress, Int32(size), startMS, max(0, durationMS))
        }
        cachedImage = nil
    }

    func flushEvents() {
        lock.lock()
        defer { lock.unlock() }
        if let track {
            ass_flush_events(track)
        }
        readOrder = 0
        cachedImage = nil
    }

    /// Render the subtitle frame at `ms`. Returns nil when nothing is visible.
    func render(atMS ms: Int64) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let renderer, let track else { return nil }
        var change: Int32 = 0
        guard let imageList = ass_render_frame(renderer, track, ms, &change) else {
            cachedImage = nil
            return nil
        }
        if change == 0, let cachedImage {
            return cachedImage
        }
        guard let cgImage = Self.blend(imageList, width: frameWidth, height: frameHeight) else {
            cachedImage = nil
            return nil
        }
        #if canImport(UIKit)
        let image = UIImage(cgImage: cgImage)
        #else
        let image = UIImage(cgImage: cgImage, size: NSSize(width: frameWidth, height: frameHeight))
        #endif
        cachedImage = image
        return image
    }

    // MARK: - Private

    private func configureFonts(defaultFontPath: String?) {
        guard let renderer else { return }
        let provider = Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue)
        if let path = defaultFontPath {
            path.withCString { fontPath in
                "sans-serif".withCString { family in
                    ass_set_fonts(renderer, fontPath, family, provider, nil, 1)
                }
            }
        } else {
            "sans-serif".withCString { family in
                ass_set_fonts(renderer, nil, family, provider, nil, 1)
            }
        }
    }

    private func applyPlayRes(from header: String) {
        guard !videoSizeSet else {
            applyFrameSize()
            return
        }
        var playX = 0
        var playY = 0
        for line in header.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("playresx:") {
                playX = Int(trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("playresy:") {
                playY = Int(trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if playX > 0, playY > 0 {
            frameWidth = playX
            frameHeight = playY
        }
        applyFrameSize()
    }

    private func applyFrameSize() {
        guard let renderer else { return }
        ass_set_frame_size(renderer, Int32(frameWidth), Int32(frameHeight))
        ass_set_storage_size(renderer, Int32(frameWidth), Int32(frameHeight))
    }

    /// Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    /// → Matroska chunk: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    private static func matroskaChunk(from raw: String, readOrder: inout Int32) -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.lowercased().hasPrefix("dialogue:") {
            if let range = line.range(of: "Dialogue:", options: .caseInsensitive) {
                line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            let fields = splitASSFields(line, limit: 10)
            guard fields.count >= 10 else {
                readOrder += 1
                return "\(readOrder),\(line)"
            }
            readOrder += 1
            return "\(readOrder),\(fields[0]),\(fields[3]),\(fields[4]),\(fields[5]),\(fields[6]),\(fields[7]),\(fields[8]),\(fields[9])"
        }
        readOrder += 1
        if line.first?.isNumber == true {
            return line
        }
        return "\(readOrder),\(line)"
    }

    private static func splitASSFields(_ line: String, limit: Int) -> [String] {
        var fields: [String] = []
        var current = ""
        for ch in line {
            if ch == ",", fields.count < limit - 1 {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    /// Blend linked `ASS_Image` list into a full-frame premultiplied-RGBA `CGImage`.
    /// Color is RRGGBBTT (TT = transparency); see FFmpeg `vf_subtitles`.
    private static func blend(_ images: UnsafeMutablePointer<ASS_Image>, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        var current: UnsafeMutablePointer<ASS_Image>? = images
        while let imgPtr = current {
            let img = imgPtr.pointee
            current = img.next
            let opacity = 255 - Int(img.color & 0xFF)
            guard opacity > 0, img.w > 0, img.h > 0, let bitmap = img.bitmap else { continue }
            let r = Int((img.color >> 24) & 0xFF)
            let g = Int((img.color >> 16) & 0xFF)
            let b = Int((img.color >> 8) & 0xFF)
            let stride = Int(img.stride)
            let dstX = Int(img.dst_x)
            let dstY = Int(img.dst_y)
            let imgW = Int(img.w)
            let imgH = Int(img.h)
            for y in 0 ..< imgH {
                let outY = dstY + y
                guard outY >= 0, outY < height else { continue }
                let srcRow = y * stride
                let dstRow = outY * width * 4
                for x in 0 ..< imgW {
                    let outX = dstX + x
                    guard outX >= 0, outX < width else { continue }
                    let srcA = Int(bitmap[srcRow + x]) * opacity / 255
                    guard srcA > 0 else { continue }
                    let di = dstRow + outX * 4
                    let dstR = Int(buffer[di])
                    let dstG = Int(buffer[di + 1])
                    let dstB = Int(buffer[di + 2])
                    let dstA = Int(buffer[di + 3])
                    let outA = srcA + dstA * (255 - srcA) / 255
                    guard outA > 0 else { continue }
                    buffer[di] = UInt8((r * srcA + dstR * dstA * (255 - srcA) / 255) / outA)
                    buffer[di + 1] = UInt8((g * srcA + dstG * dstA * (255 - srcA) / 255) / outA)
                    buffer[di + 2] = UInt8((b * srcA + dstB * dstA * (255 - srcA) / 255) / outA)
                    buffer[di + 3] = UInt8(outA)
                }
            }
        }
        let pixelCount = width * height
        for i in 0 ..< pixelCount {
            let o = i * 4
            let a = Int(buffer[o + 3])
            if a == 0 || a == 255 { continue }
            buffer[o] = UInt8(Int(buffer[o]) * a / 255)
            buffer[o + 1] = UInt8(Int(buffer[o + 1]) * a / 255)
            buffer[o + 2] = UInt8(Int(buffer[o + 2]) * a / 255)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return ctx.makeImage()
    }
}
