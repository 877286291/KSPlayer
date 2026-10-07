//
//  SubtitleDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import CoreGraphics
import Foundation
import Libavformat
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

class SubtitleDecode: DecodeProtocol {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private let scale = VideoSwresample(dstFormat: AV_PIX_FMT_ARGB, isDovi: false)
    private var subtitle = AVSubtitle()
    private var startTime = TimeInterval(0)
    private let assParse = AssParse()
    private weak var assetTrack: FFmpegAssetTrack?
    private var assRenderer: AssImageRenderer?
    /// True once we've successfully fed at least one ASS chunk to libass.
    private var usesLibass = false

    required init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.assetTrack = assetTrack
        startTime = assetTrack.startTime.seconds
        do {
            codecContext = try assetTrack.createContext(options: options)
            if KSOptions.enableLibass,
               let renderer = AssImageRenderer(
                   fontsDirectory: KSOptions.assFontsDirectory,
                   defaultFontPath: KSOptions.assDefaultFontPath
               )
            {
                if options.assVideoSize.width > 0, options.assVideoSize.height > 0 {
                    renderer.setVideoSize(options.assVideoSize)
                }
                if let pointer = codecContext?.pointee.subtitle_header {
                    let size = Int(codecContext?.pointee.subtitle_header_size ?? 0)
                    if size > 0 {
                        renderer.setCodecPrivate(pointer, size: size)
                    }
                }
                assRenderer = renderer
                assetTrack.assRenderer = renderer
            } else if let pointer = codecContext?.pointee.subtitle_header {
                let subtitleHeader = String(cString: pointer)
                _ = assParse.canParse(scanner: Scanner(string: subtitleHeader))
            }
        } catch {
            KSLog(error as CustomStringConvertible)
        }
    }

    func decode() {}

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let codecContext else {
            return
        }
        var gotsubtitle = Int32(0)
        _ = avcodec_decode_subtitle2(codecContext, &subtitle, &gotsubtitle, packet.corePacket)
        if gotsubtitle == 0 {
            return
        }
        let timestamp = packet.timestamp
        var start = packet.assetTrack.timebase.cmtime(for: timestamp).seconds + TimeInterval(subtitle.start_display_time) / 1000.0
        if start >= startTime {
            start -= startTime
        }
        var duration = 0.0
        if subtitle.end_display_time != UInt32.max {
            duration = TimeInterval(subtitle.end_display_time - subtitle.start_display_time) / 1000.0
        }
        if duration == 0, packet.duration != 0 {
            duration = packet.assetTrack.timebase.cmtime(for: packet.duration).seconds
        }
        let parts = text(subtitle: subtitle, start: start, duration: duration)
        /// libass path: events live in the AssImageRenderer track; search() re-renders by time.
        /// Still enqueue a lightweight marker so flush/seek drains stay consistent when needed.
        if usesLibass, parts.isEmpty {
            avsubtitle_free(&subtitle)
            return
        }
        var emit = parts
        /// 不用preSubtitleFrame来进行更新end。而是插入一个空的字幕来更新字幕。
        /// 因为字幕有可能不按顺序解码。这样就会导致end比start小，然后这个字幕就不会被清空了。
        if emit.isEmpty {
            emit.append(SubtitlePart(0, 0, attributedString: nil))
        }
        for part in emit {
            part.start = start
            if duration == 0 {
                part.end = .infinity
            } else {
                part.end = start + duration
            }
            let frame = SubtitleFrame(part: part, timebase: packet.assetTrack.timebase)
            frame.timestamp = timestamp
            completionHandler(.success(frame))
        }
        avsubtitle_free(&subtitle)
    }

    func doFlushCodec() {
        assRenderer?.flushEvents()
        usesLibass = false
    }

    func shutdown() {
        scale.shutdown()
        avsubtitle_free(&subtitle)
        assRenderer?.shutdown()
        assRenderer = nil
        assetTrack?.assRenderer = nil
        if let codecContext {
            avcodec_close(codecContext)
            avcodec_free_context(&self.codecContext)
        }
    }

    private func text(subtitle: AVSubtitle, start: TimeInterval, duration: TimeInterval) -> [SubtitlePart] {
        var parts = [SubtitlePart]()
        var images = [(CGRect, CGImage)]()
        var origin: CGPoint = .zero
        var attributedString: NSMutableAttributedString?
        let startMS = Int64((start * 1000).rounded())
        let durationMS = Int64((max(duration, 0) * 1000).rounded())
        for i in 0 ..< Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i]?.pointee else {
                continue
            }
            if i == 0 {
                origin = CGPoint(x: Int(rect.x), y: Int(rect.y))
            }
            if let text = rect.text {
                if attributedString == nil {
                    attributedString = NSMutableAttributedString()
                }
                attributedString?.append(NSAttributedString(string: String(cString: text)))
            } else if let ass = rect.ass {
                let event = String(cString: ass)
                if let assRenderer {
                    assRenderer.processChunk(event, startMS: startMS, durationMS: durationMS)
                    usesLibass = true
                } else {
                    let scanner = Scanner(string: event)
                    if let group = assParse.parsePart(scanner: scanner) {
                        parts.append(group)
                    }
                }
            } else if rect.type == SUBTITLE_BITMAP {
                if let image = scale.transfer(format: AV_PIX_FMT_PAL8, width: rect.w, height: rect.h, data: Array(tuple: rect.data), linesize: Array(tuple: rect.linesize))?.cgImage() {
                    images.append((CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h)), image))
                }
            }
        }
        if images.count > 0 {
            let part = SubtitlePart(0, 0, attributedString: nil)
            if images.count > 1 {
                origin = .zero
            }
            var image: UIImage?
            // 因为字幕需要有透明度,所以不能用jpg；tif在iOS支持没有那么好，会有绿色背景； 用heic格式，展示的时候会卡主线程；所以最终用png。
            if let data = CGImage.combine(images: images)?.data(type: .png, quality: 0.2) {
                image = UIImage(data: data)
            }
            part.image = image
            part.origin = origin
            parts.append(part)
        }
        if let attributedString {
            parts.append(SubtitlePart(0, 0, attributedString: attributedString))
        }
        return parts
    }
}
