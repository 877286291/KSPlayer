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
            if let image = assRenderer.render(atMS: ms) {
                let part = SubtitlePart(time, time + 0.25, attributedString: nil)
                part.image = image
                part.origin = .zero
                return [part]
            }
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
