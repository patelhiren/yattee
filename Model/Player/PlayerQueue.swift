import AVKit
import Defaults
import Foundation
import Siesta

extension PlayerModel {
    var currentVideo: Video? {
        currentItem?.video
    }

    func playAll(_ videos: [Video]) {
        let first = videos.first

        videos.forEach { video in
            enqueueVideo(video) { _, item in
                if item.video == first {
                    self.advanceToItem(item)
                }
            }
        }
    }

    func playNext(_ video: Video) {
        enqueueVideo(video, prepending: true) { _, item in
            if self.currentItem.isNil {
                self.advanceToItem(item)
            }
        }
    }

    func playNow(_ video: Video, at time: TimeInterval? = nil) {
        if playingInPictureInPicture, closePiPOnNavigation {
            closePiP()
        }

        prepareCurrentItemForHistory()

        enqueueVideo(video, prepending: true) { _, item in
            self.advanceToItem(item, at: time)
        }
    }

    func playItem(_ item: PlayerQueueItem, video: Video? = nil, at time: TimeInterval? = nil) {
        if !playingInPictureInPicture {
            player.replaceCurrentItem(with: nil)
        }

        comments.reset()
        stream = nil
        currentItem = item

        if !time.isNil {
            currentItem.playbackTime = .secondsInDefaultTimescale(time!)
        } else if currentItem.playbackTime.isNil {
            currentItem.playbackTime = .zero
        }

        if video != nil {
            currentItem.video = video!
        }

        preservedTime = currentItem.playbackTime
        restoreLoadedChannel()

        DispatchQueue.main.async { [weak self] in
            guard let video = self?.currentVideo else {
                return
            }

            self?.loadAvailableStreams(video)
        }
    }

    func preferredStream(_ streams: [Stream]) -> Stream? {
        let quality = Defaults[.quality]
        var streams = streams

        if let id = Defaults[.playerInstanceID] {
            streams = streams.filter { $0.instance.id == id }
        }

        switch quality {
        case .best:
            return streams.first { $0.kind == .hls } ?? streams.first
        default:
            let sorted = streams.filter { $0.kind != .hls }.sorted { $0.resolution > $1.resolution }
            return sorted.first(where: { $0.resolution.height <= quality.value.height })
        }
    }

    func advanceToNextItem() {
        prepareCurrentItemForHistory()

        if let nextItem = queue.first {
            advanceToItem(nextItem)
        }
    }

    func advanceToItem(_ newItem: PlayerQueueItem, at time: TimeInterval? = nil) {
        prepareCurrentItemForHistory()

        remove(newItem)

        currentItem = newItem
        player.pause()

        accounts.api.loadDetails(newItem) { newItem in
            self.playItem(newItem, video: newItem.video, at: time)
        }
    }

    @discardableResult func remove(_ item: PlayerQueueItem) -> PlayerQueueItem? {
        if let index = queue.firstIndex(where: { $0.videoID == item.videoID }) {
            return queue.remove(at: index)
        }

        return nil
    }

    func resetQueue() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            self.currentItem = nil
            self.stream = nil
            self.removeQueueItems()
        }

        player.replaceCurrentItem(with: nil)
    }

    func isAutoplaying(_ item: AVPlayerItem) -> Bool {
        player.currentItem == item
    }

    @discardableResult func enqueueVideo(
        _ video: Video,
        play: Bool = false,
        atTime: CMTime? = nil,
        prepending: Bool = false,
        videoDetailsLoadHandler: @escaping (Video, PlayerQueueItem) -> Void = { _, _ in }
    ) -> PlayerQueueItem? {
        let item = PlayerQueueItem(video, playbackTime: atTime)

        if play {
            currentItem = item
            // pause playing current video as it's going to be replaced with next one
            player.pause()
        }

        queue.insert(item, at: prepending ? 0 : queue.endIndex)

        accounts.api.loadDetails(item) { newItem in
            videoDetailsLoadHandler(newItem.video, newItem)

            if play {
                self.playItem(newItem, video: video)
            }
        }

        return item
    }

    func prepareCurrentItemForHistory(finished: Bool = false) {
        if !currentItem.isNil, Defaults[.saveHistory] {
            if let video = currentVideo, !historyVideos.contains(where: { $0 == video }) {
                historyVideos.append(video)
            }
            updateWatch(finished: finished)
        }
    }

    func playHistory(_ item: PlayerQueueItem) {
        var time = item.playbackTime

        if item.shouldRestartPlaying {
            time = .zero
        }

        let newItem = enqueueVideo(item.video, atTime: time, prepending: true)

        advanceToItem(newItem!)
    }

    func removeQueueItems() {
        queue.removeAll()
    }
}
