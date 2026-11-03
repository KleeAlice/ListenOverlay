import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@main
enum AudioCaptureTests {
    static func main() throws {
        // Exercise both ScreenCaptureKit-compatible layouts. The copy must keep
        // every channel and remain valid after the sample's backing store changes.
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                                       interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            pcm.frameLength = 4
            for channel in 0..<2 {
                for frame in 0..<4 {
                    if interleaved { pcm.floatChannelData![0][frame * 2 + channel] = Float(channel + frame) / 10 }
                    else { pcm.floatChannelData![channel][frame] = Float(channel + frame) / 10 }
                }
            }
            var description: CMAudioFormatDescription?
            precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                                                        layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                        magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
            var sample: CMSampleBuffer?
            precondition(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                                                          dataReady: false, makeDataReadyCallback: nil,
                                                                          refcon: nil, formatDescription: description!,
                                                                          sampleCount: 4, presentationTimeStamp: .zero,
                                                                          packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
            precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
                                                                      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                      bufferList: pcm.audioBufferList) == noErr)
            precondition(CMSampleBufferSetDataReady(sample!) == noErr)
            let copy = try SystemAudioCapture.copyPCM(from: sample!)
            precondition(copy.frameLength == 4 && copy.format.channelCount == 2)
            let expected: Float = 0.4
            let last = interleaved ? copy.floatChannelData![0][7] : copy.floatChannelData![1][3]
            precondition(abs(last - expected) < 0.00001)
            let block = CMSampleBufferGetDataBuffer(sample!)!
            precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                                  dataLength: CMBlockBufferGetDataLength(block)) == noErr)
            let retained = interleaved ? copy.floatChannelData![0][7] : copy.floatChannelData![1][3]
            precondition(abs(retained - expected) < 0.00001, "Copied audio must not borrow sample memory.")
        }
        let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 4)!
        mono.frameLength = 4
        for index in 0..<4 { mono.floatChannelData![0][index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        precondition(abs(SystemAudioCapture.rms(mono) - 0.5) < 0.00001)
        precondition(SystemAudioCapture.isTemporary(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noCaptureSource.rawValue)))
        precondition(!SystemAudioCapture.isTemporary(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
        precondition(!SystemAudioCapture.isTemporary(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)))
        precondition(SystemAudioCapture.needsPermission(SystemAudioCapture.CaptureError.permission))
        precondition(!SystemAudioCapture.needsPermission(SystemAudioCapture.CaptureError.noDisplay))
        print("Audio capture: planar/interleaved ownership and RMS checks passed")
    }
}
