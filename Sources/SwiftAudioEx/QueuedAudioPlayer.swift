//
//  QueuedAudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 24/03/2018.
//

import Foundation
import MediaPlayer

/**
 An audio player that can keep track of a queue of AudioItems.
 */
public class QueuedAudioPlayer: AudioPlayer, QueueManagerDelegate {
    let queue: QueueManager = QueueManager<AudioItem>()
    fileprivate var lastIndex: Int = -1
    fileprivate var lastItem: AudioItem? = nil

    // Add a property to store the time observer
    private var timeObserverToken: Any?
    // Add a flag to track whether the next function has been called
    private var hasCalledNext = false
    // Define the threshold for starting the volume decay
    private let volumeDecayThreshold: TimeInterval = 0.2 // 400 ms
    // Define the duration for the fade-in effect
    private let fadeInDuration: TimeInterval = 0.1 // 350 ms
    // Define the number of steps for the fade effect
    private let fadeSteps = 5 // Adjust this value as needed

    public override init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(), remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        super.init(nowPlayingInfoController: nowPlayingInfoController, remoteCommandController: remoteCommandController)
        queue.delegate = self
        addPeriodicTimeObserver()
    }

    deinit {
        if let timeObserverToken = timeObserverToken {
            wrapper.getAVPlayer().removeTimeObserver(timeObserverToken)
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.01, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = wrapper.getAVPlayer().addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.checkForTrackEnd(time: time)
        }
    }

    private func checkForTrackEnd(time: CMTime) {
        guard let currentItem = wrapper.getAVPlayer().currentItem else { return }
        let currentTime = CMTimeGetSeconds(time)
        let duration = CMTimeGetSeconds(currentItem.duration)
        let remainingTime = duration - currentTime

        // Check if the remaining time is less than or equal to 300 milliseconds
        if remainingTime <= 0.1 && !hasCalledNext {
            // Ensure there's a next track available in the queue
            if !queue.nextItems.isEmpty {
                hasCalledNext = true
                loadNextItem()
            } else {
                // No more items in the queue, set the state to ended
                wrapper.state = .ended
            }
        }
    }

    private func applyQuadraticVolumeDecay() {
        let initialVolume = wrapper.getAVPlayer().volume
        let decayDuration = volumeDecayThreshold
        let decayStepDuration = decayDuration / Double(fadeSteps)

        for step in 0..<fadeSteps {
            let delay = decayStepDuration * Double(step)
            let volume = initialVolume * pow(Float(1.0 - Double(step) / Double(fadeSteps)), 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.wrapper.getAVPlayer().volume = Float(volume)
                
                // Load the next item when the fade-out is halfway through
                if step == fadeSteps / 2 {
                    self.loadNextItem()
                }
            }
        }
    }

    private func loadNextItem() {
        if let nextItem = queue.next(wrap: repeatMode == .queue) {
            super.load(item: nextItem)
            play()
            //applyQuadraticFadeIn()
            hasCalledNext = false // Reset the flag
        }
    }

    private func applyQuadraticFadeIn() {
        let fadeInSteps = 20
        let fadeInStepDuration = fadeInDuration / Double(fadeInSteps)
        let initialVolume: Float = 0.0
        wrapper.getAVPlayer().volume = initialVolume

        for step in 0..<fadeInSteps {
            let delay = fadeInStepDuration * Double(step)
            let volume = pow(Double(step) / Double(fadeInSteps), 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.wrapper.getAVPlayer().volume = Float(volume)
            }
        }
    }

    /// The repeat mode for the queue player.
    public var repeatMode: RepeatMode = .off

    public override var currentItem: AudioItem? {
        queue.current
    }

    /**
     The index of the current item.
     */
    public var currentIndex: Int {
        queue.currentIndex
    }

    override public func clear() {
        queue.clearQueue()
        super.clear()
    }

    /**
     All items currently in the queue.
     */
    public var items: [AudioItem] {
        queue.items
    }

    /**
     The previous items held by the queue.
     */
    public var previousItems: [AudioItem] {
        queue.previousItems
    }

    /**
     The upcoming items in the queue.
     */
    public var nextItems: [AudioItem] {
        queue.nextItems
    }

    /**
     Will replace the current item with a new one and load it into the player.

     - parameter item: The AudioItem to replace the current item.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public override func load(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.replaceCurrentItem(with: item)
        }
    }

    /**
     Add a single item to the queue.

     - parameter item: The item to add.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(item)
        }
    }

    /**
     Add items to the queue.

     - parameter items: The items to add to the queue.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(items: [AudioItem], playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(items)
        }
    }

    public func add(items: [AudioItem], at index: Int) throws {
        try queue.add(items, at: index)
    }

    /**
     Step to the next item in the queue.
     */
    public func next() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.next(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToNext)
        }
    }

    /**
     Step to the previous item in the queue.
     */
    public func previous() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.previous(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToPrevious)
        }
    }

    /**
     Remove an item from the queue.

     - parameter index: The index of the item to remove.
     - throws: `AudioPlayerError.QueueError`
     */
    public func removeItem(at index: Int) throws {
        try queue.removeItem(at: index)
    }


    /**
     Jump to a certain item in the queue.

     - parameter index: The index of the item to jump to.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     - throws: `AudioPlayerError`
     */
    public func jumpToItem(atIndex index: Int, playWhenReady: Bool? = nil) throws {
        try handlePlayWhenReady(playWhenReady) {
            if (index == currentIndex) {
                seek(to: 0)
            } else {
                _ = try queue.jump(to: index)
            }
            event.playbackEnd.emit(data: .jumpedToIndex)
        }
    }

    /**
     Move an item in the queue from one position to another.

     - parameter fromIndex: The index of the item to move.
     - parameter toIndex: The index to move the item to.
     - throws: `AudioPlayerError.QueueError`
     */
    public func moveItem(fromIndex: Int, toIndex: Int) throws {
        try queue.moveItem(fromIndex: fromIndex, toIndex: toIndex)
    }

    /**
     Remove all upcoming items, those returned by `next()`
     */
    public func removeUpcomingItems() {
        queue.removeUpcomingItems()
    }

    /**
     Remove all previous items, those returned by `previous()`
     */
    public func removePreviousItems() {
        queue.removePreviousItems()
    }

    func replay() {
        seek(to: 0);
        play()
    }

    // MARK: - AVPlayerWrapperDelegate
    override func AVWrapperItemDidPlayToEndTime() {
        event.playbackEnd.emit(data: .playedUntilEnd)
        
        if repeatMode == .track {
            self.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016 * 2) { [weak self] in self?.replay() }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let nextItem = self.queue.next(wrap: self.repeatMode == .queue)
                if let nextItem = nextItem {
                    self.load(item: nextItem)
                    self.play() // Ensure the next item starts playing
                    self.hasCalledNext = false // Reset the flag
                } else {
                    self.wrapper.state = .ended
                }
            }
        }
    }

    // MARK: - QueueManagerDelegate

    func onCurrentItemChanged() {
        let lastPosition = currentTime;
        if let currentItem = currentItem {
            super.load(item: currentItem)
        } else {
            super.clear()
        }
        event.currentItem.emit(
            data: (
                item: currentItem,
                index: currentIndex == -1 ? nil : currentIndex,
                lastItem: lastItem,
                lastIndex: lastIndex == -1 ? nil : lastIndex,
                lastPosition: lastPosition
            )
        )
        lastItem = currentItem
        lastIndex = currentIndex
    }

    func onSkippedToSameCurrentItem() {
        if (wrapper.playbackActive) {
            replay()
        }
    }

    func onReceivedFirstItem() {
        try! queue.jump(to: 0)
    }

public func preloadNext(numberOfTracks: Int = 1) {
    let nextItems = queue.nextItems

    for i in 0..<min(numberOfTracks, nextItems.count) {
        self.preload(item: nextItems[i])
    }
}

}
