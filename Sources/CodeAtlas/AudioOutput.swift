import CoreAudio
import Foundation

/// Hardware status only; nothing changes until unmuteCurrentDefault() is invoked
/// by the explicitly labeled user action in AudioPreview.
enum AudioOutput {
    struct Status {
        let device:AudioObjectID
        let muted:Bool?
        let volume:Float?
        let canUnmute:Bool
    }
    enum UnmuteResult {
        case confirmed,unavailable,deviceChanged,notSettable,failed,unconfirmed
        var message:String {
            switch self {
            case .confirmed:return "Mac output is now unmuted."
            case .unavailable:return "Mac output status is unavailable. Check Sound settings."
            case .deviceChanged:return "The output device changed. Check its mute state and try again."
            case .notSettable:return "This device’s mute setting must be changed in Sound settings."
            case .failed:return "Mac output could not be unmuted. Check Sound settings."
            case .unconfirmed:return "The mute change could not be confirmed. Check Sound settings."
            }
        }
    }
    static func status()->Status? {
        guard let device=defaultDevice() else {return nil}
        let mute:UInt32?=read(device,selector:kAudioDevicePropertyMute,initial:UInt32(0))
        let rawVolume:Float32?=read(device,selector:kAudioDevicePropertyVolumeScalar,initial:Float32(0))
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var settable:DarwinBoolean=false
        let canSet=AudioObjectIsPropertySettable(device,&address,&settable)==noErr && settable.boolValue
        return Status(device:device,muted:mute.map {$0 != 0},volume:rawVolume.flatMap {$0.isFinite ? min(1,max(0,$0)) : nil},canUnmute:canSet)
    }
    static func unmuteCurrentDefault()->UnmuteResult {
        guard let current=status(),let muted=current.muted else {return .unavailable}
        guard muted else {return .confirmed}
        guard current.canUnmute else {return .notSettable}
        guard defaultDevice()==current.device else {return .deviceChanged}
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var unmuted:UInt32=0
        guard AudioObjectSetPropertyData(current.device,&address,0,nil,UInt32(MemoryLayout<UInt32>.size),&unmuted)==noErr else {return .failed}
        guard let after=status(),after.device==current.device else {return .deviceChanged}
        return after.muted == false ? .confirmed : .unconfirmed
    }
    private static func defaultDevice()->AudioObjectID? {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var device=AudioObjectID(kAudioObjectUnknown),size=UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr,device != kAudioObjectUnknown else {return nil}
        return device
    }
    private static func read<T>(_ device:AudioObjectID,selector:AudioObjectPropertySelector,initial:T)->T? {
        var address=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device,&address) else {return nil}
        var value=initial,size=UInt32(MemoryLayout<T>.size)
        let result=withUnsafeMutableBytes(of:&value) { bytes in
            AudioObjectGetPropertyData(device,&address,0,nil,&size,bytes.baseAddress!)
        }
        guard result==noErr,size==MemoryLayout<T>.size else {return nil}
        return value
    }
}
