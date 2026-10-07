//
//  EmbedDataSouce.swift
//  KSPlayer-7de52535
//
//  Created by kintan on 2018/8/7.
//
import Foundation
import Libavcodec
import Libavutil

extension FFmpegAssetTrack: SubtitleInfo {
    public var subtitleID: String {
        String(trackID)
    }
}

extension FFmpegAssetTrack: KSSubtitleProtocol {
    public func search(for time: TimeInterval) -> [SubtitlePart] {
        // Drain the decode ring so stepped-over cues do not leak slots.
        let decoded = subtitle?.outputRenderQueue.search { item -> Bool in
            item.part == time
        }.map(\.part) ?? []
        // libass path: re-render at the current clock so karaoke / move / fade animate.
        if let assRenderer {
            let ms = Int64((time * 1000).rounded())
            if let output = assRenderer.render(atMS: ms) {
                // Reuse the same SubtitlePart + UIImage when libass reports no change,
                // so hosts can skip SwiftUI publishes and avoid main-thread churn.
                if let cached = assSubtitlePart, cached.image === output.image {
                    cached.start = time
                    cached.end = time + 0.5
                    return [cached]
                }
                let part = SubtitlePart(time, time + 0.5, attributedString: nil)
                part.image = output.image
                part.origin = output.origin
                part.canvasSize = output.canvasSize
                assSubtitlePart = part
                return [part]
            }
            assSubtitlePart = nil
            return []
        }
        return decoded
    }
}

extension KSMEPlayer: SubtitleDataSouce {
    public var infos: [any SubtitleInfo] {
        tracks(mediaType: .subtitle).compactMap { $0 as? (any SubtitleInfo) }
    }
}
