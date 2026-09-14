import AppKit
import AVFoundation

/// A local audio transport with explicit application volume and bounded time updates.
final class AudioPreview:NSView {
    private let player:AVPlayer
    private let playButton=NSButton(title:"Play",target:nil,action:nil)
    private let previous=NSButton(title:"−15s",target:nil,action:nil)
    private let next=NSButton(title:"+15s",target:nil,action:nil)
    private let scrubber=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil)
    private let elapsed=NSTextField(labelWithString:"0:00")
    private let durationLabel=NSTextField(labelWithString:"—:—")
    private let state=NSTextField(labelWithString:"Loading audio…")
    private let volume=NSSlider(value:1,minValue:0,maxValue:1,target:nil,action:nil)
    private let mute=NSButton(title:"Mute",target:nil,action:nil)
    private let output=NSTextField(labelWithString:"Player volume 100%")
    private let macOutput=NSTextField(wrappingLabelWithString:"Checking Mac output…")
    private let unmuteMac=NSButton(title:"Unmute Mac",target:nil,action:nil)
    private var outputTimer:Timer?
    private var outputActionMessage:String?
    private var outputActionExpiry=Date.distantPast
    private var itemObservation:NSKeyValueObservation?
    private var playbackObservation:NSKeyValueObservation?
    private var durationObservation:NSKeyValueObservation?
    private var timeObserver:Any?
    private var endObserver:NSObjectProtocol?
    private var failureObserver:NSObjectProtocol?
    private var duration:Double=0
    private var metadataTask:Task<Void,Never>?
    private var missingAudioTrack=false
    private var ready=false
    private var ended=false
    private var stopped=false
    private var seekGeneration=0
    var preferredResponder:NSResponder {playButton}

    init(url:URL) {
        let item=AVPlayerItem(url:url)
        player=AVPlayer(playerItem:item)
        super.init(frame:.zero)
        player.volume=1; player.isMuted=false
        wantsLayer=true
        let icon=NSImageView()
        icon.image=NSImage(systemSymbolName:"waveform",accessibilityDescription:"Audio recording")
        icon.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:42,weight:.regular)
        icon.contentTintColor = .controlAccentColor
        let title=NSTextField(labelWithString:"Audio")
        title.font = .systemFont(ofSize:24,weight:.semibold)
        state.font = .systemFont(ofSize:13); state.textColor = .secondaryLabelColor
        state.alignment = .center
        state.setAccessibilityLabel("Playback status")
        playButton.target=self; playButton.action=#selector(togglePlayback)
        playButton.bezelStyle = .rounded; playButton.setAccessibilityLabel("Play audio")
        previous.target=self; previous.action=#selector(skipBack); previous.setAccessibilityLabel("Back 15 seconds")
        next.target=self; next.action=#selector(skipForward); next.setAccessibilityLabel("Forward 15 seconds")
        scrubber.target=self; scrubber.action=#selector(scrub); scrubber.isContinuous=false
        scrubber.setAccessibilityLabel("Audio playback position")
        volume.target=self; volume.action=#selector(changeVolume); volume.isContinuous=true
        volume.setAccessibilityLabel("Audio volume")
        mute.target=self; mute.action=#selector(toggleMute); mute.setAccessibilityLabel("Mute audio")
        output.font = .systemFont(ofSize:12); output.textColor = .secondaryLabelColor
        for label in [elapsed,durationLabel] {label.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)}
        let timeline=NSStackView(views:[elapsed,scrubber,durationLabel]); timeline.spacing=12
        let transport=NSStackView(views:[previous,playButton,next]); transport.spacing=16
        let volumeRow=NSStackView(views:[mute,volume]); volumeRow.spacing=12
        macOutput.font = .systemFont(ofSize:12,weight:.medium); macOutput.alignment = .center
        macOutput.setAccessibilityLabel("Mac audio output status")
        unmuteMac.target=self; unmuteMac.action=#selector(unmuteMacOutput)
        unmuteMac.setAccessibilityLabel("Unmute Mac system output")
        unmuteMac.toolTip="Unmutes the current Mac output device. This changes system sound for other apps too."
        unmuteMac.isHidden=true
        let card=NSStackView(views:[icon,title,state,timeline,transport,volumeRow,output,macOutput,unmuteMac])
        card.orientation = .vertical; card.alignment = .centerX; card.spacing=18
        card.translatesAutoresizingMaskIntoConstraints=false; addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo:centerXAnchor),card.centerYAnchor.constraint(equalTo:centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-48),
            timeline.widthAnchor.constraint(equalTo:card.widthAnchor),
            macOutput.widthAnchor.constraint(equalTo:card.widthAnchor),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant:100),
            volume.widthAnchor.constraint(equalToConstant:160),
            playButton.widthAnchor.constraint(equalToConstant:100),
            icon.widthAnchor.constraint(equalToConstant:58),icon.heightAnchor.constraint(equalToConstant:52)
        ])
        let preferredWidth=card.widthAnchor.constraint(equalToConstant:520); preferredWidth.priority = .defaultHigh; preferredWidth.isActive=true
        enableTransport(false)
        refreshMacOutput()
        let outputTimer=Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.refreshMacOutput() }
        self.outputTimer=outputTimer; RunLoop.main.add(outputTimer,forMode:.common)
        metadataTask=Task { [weak self] in
            do {
                let tracks=try await item.asset.loadTracks(withMediaType:.audio)
                guard !Task.isCancelled else {return}
                if tracks.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,!self.stopped else {return}
                        self.missingAudioTrack=true; self.showFailure()
                    }
                }
            } catch {
                // AVPlayerItem.status remains the authority for actual playback failure.
            }
        }
        itemObservation=item.observe(\.status,options:[.initial,.new]) { [weak self] _,_ in
            DispatchQueue.main.async { [weak self] in self?.updateReadiness() }
        }
        durationObservation=item.observe(\.duration,options:[.initial,.new]) { [weak self] _,_ in
            DispatchQueue.main.async { [weak self] in self?.updateDuration() }
        }
        playbackObservation=player.observe(\.timeControlStatus,options:[.new]) { [weak self] _,_ in
            DispatchQueue.main.async { [weak self] in self?.updatePlaybackState() }
        }
        timeObserver=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:600),queue:.main) { [weak self] time in
            guard let self,!self.stopped else {return}
            let seconds=time.seconds
            guard seconds.isFinite else {return}
            self.elapsed.stringValue=Self.clock(seconds)
            if self.scrubber.cell?.isHighlighted != true {self.scrubber.doubleValue=max(0,seconds)}
        }
        endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in
            guard let self,!self.stopped else {return}
            self.ended=true; self.player.pause(); self.updatePlaybackState()
        }
        failureObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemFailedToPlayToEndTime,object:item,queue:.main) { [weak self] _ in
            self?.showFailure()
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    func pausePlayback() {guard !stopped else {return};player.pause();updatePlaybackState()}
    deinit {stop()}
    func stop() {
        guard !stopped else {return}
        stopped=true; seekGeneration += 1; metadataTask?.cancel(); metadataTask=nil; player.pause()
        outputTimer?.invalidate(); outputTimer=nil
        if let timeObserver {player.removeTimeObserver(timeObserver);self.timeObserver=nil}
        if let endObserver {NotificationCenter.default.removeObserver(endObserver);self.endObserver=nil}
        if let failureObserver {NotificationCenter.default.removeObserver(failureObserver);self.failureObserver=nil}
        itemObservation=nil; durationObservation=nil; playbackObservation=nil
    }
    private func enableTransport(_ enabled:Bool) {
        playButton.isEnabled=enabled; previous.isEnabled=enabled && duration>0; next.isEnabled=enabled && duration>0
        scrubber.isEnabled=enabled && duration>0
    }
    private func updateReadiness() {
        guard !stopped,let item=player.currentItem else {return}
        if missingAudioTrack {showFailure();return}
        switch item.status {
        case .readyToPlay: ready=true; updateDuration(); enableTransport(true); updatePlaybackState()
        case .failed: showFailure()
        default: ready=false; enableTransport(false); state.stringValue="Loading audio…"
        }
    }
    private func updateDuration() {
        guard !stopped else {return}
        let seconds=player.currentItem?.duration.seconds ?? .nan
        duration=seconds.isFinite && seconds>0 ? seconds : 0
        durationLabel.stringValue=duration>0 ? Self.clock(duration) : "—:—"
        scrubber.maxValue=max(1,duration); enableTransport(ready)
    }
    private func updatePlaybackState() {
        guard !stopped,ready else {return}
        let running=player.timeControlStatus != .paused
        playButton.title=ended ? "Replay" : (running ? "Pause" : "Play")
        playButton.setAccessibilityLabel(ended ? "Replay audio" : (running ? "Pause audio" : "Play audio"))
        if ended {state.stringValue="Finished"}
        else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {state.stringValue="Preparing playback…"}
        else {state.stringValue=running ? "Playing" : "Ready · Press Play to listen"}
        updateOutput()
    }
    private func showFailure() {
        guard !stopped else {return}
        ready=false; player.pause(); enableTransport(false)
        state.stringValue=missingAudioTrack ? "No audio track was found in this file." : "Audio could not play here. Try Open in Default App."
        playButton.title="Play"; playButton.setAccessibilityLabel("Play audio")
    }
    @objc private func togglePlayback() {
        guard ready,!stopped else {return}
        if player.timeControlStatus != .paused {player.pause()}
        else if ended {seek(to:0,resume:true)}
        else {player.play()}
        updatePlaybackState()
    }
    @objc private func skipBack() {seek(to:currentSeconds-15)}
    @objc private func skipForward() {seek(to:currentSeconds+15)}
    @objc private func scrub() {seek(to:scrubber.doubleValue)}
    private var currentSeconds:Double {let value=player.currentTime().seconds; return value.isFinite ? value : 0}
    private func seek(to seconds:Double,resume:Bool=false) {
        guard ready,!stopped,duration>0 else {return}
        ended=false; seekGeneration += 1; let generation=seekGeneration
        let target=min(duration,max(0,seconds)); elapsed.stringValue=Self.clock(target); scrubber.doubleValue=target
        let tolerance=CMTime(seconds:0.1,preferredTimescale:600)
        player.seek(to:CMTime(seconds:target,preferredTimescale:600),toleranceBefore:tolerance,toleranceAfter:tolerance) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self,!self.stopped,self.seekGeneration==generation else {return}
                if finished && resume {self.player.play()}
                self.updatePlaybackState()
            }
        }
    }
    @objc private func changeVolume() {
        player.volume=Float(volume.doubleValue)
        // Moving the volume up is an explicit request to hear audio.
        if volume.doubleValue>0 {player.isMuted=false}
        updateOutput()
    }
    @objc private func toggleMute() {player.isMuted.toggle();updateOutput()}
    private func updateOutput() {
        let percent=Int((player.volume*100).rounded())
        mute.title=player.isMuted ? "Unmute" : "Mute"
        mute.setAccessibilityLabel(player.isMuted ? "Unmute audio" : "Mute audio")
        output.stringValue=player.isMuted ? "Player muted · Volume \(percent)%" : (percent==0 ? "Player volume 0% · Raise volume to hear audio" : "Player volume \(percent)%")
    }
    private func refreshMacOutput() {
        guard !stopped else {return}
        let status=AudioOutput.status()
        unmuteMac.isHidden = status?.muted != true || status?.canUnmute != true
        macOutput.textColor = status?.muted == true || status?.volume == 0 ? .systemOrange : .secondaryLabelColor
        let message:String
        if let status {
            if status.muted == true {message="Mac output is muted"}
            else if let volume=status.volume {
                let percent=Int((volume*100).rounded())
                message=percent==0 ? "Mac output volume is 0% · Raise volume in Sound settings" : "Mac output volume \(percent)%"+(status.muted == nil ? " · Mute status unavailable" : " · Unmuted")
            } else {message=status.muted == false ? "Mac output is unmuted · Volume status unavailable" : "Mac output status is unavailable"}
        } else {message="Mac output status is unavailable"}
        if let action=outputActionMessage,Date()<outputActionExpiry {macOutput.stringValue=message+"\n"+action}
        else {outputActionMessage=nil;macOutput.stringValue=message}
    }
    @objc private func unmuteMacOutput() {
        guard !stopped else {return}
        // Deliberately never called by readiness, Play, volume, or polling.
        // Only the user-facing Unmute Mac control invokes a hardware change.
        let result=AudioOutput.unmuteCurrentDefault()
        outputActionMessage=result.message; outputActionExpiry=Date().addingTimeInterval(6)
        refreshMacOutput()
    }
    private static func clock(_ seconds:Double)->String {
        let total=Int(max(0,seconds)),hours=total/3600,minutes=(total/60)%60,remainder=total%60
        return hours>0 ? String(format:"%d:%02d:%02d",hours,minutes,remainder) : String(format:"%d:%02d",minutes,remainder)
    }
}
