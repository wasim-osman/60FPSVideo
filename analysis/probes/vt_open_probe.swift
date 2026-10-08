import AVFoundation
import CoreMedia
import Foundation

// What can AVFoundation actually open?
//
// This matters more than it looks. AVAssetReader is the only sane way to get
// decoded frames with exact timing and colour metadata on macOS, so it is what the
// app will use. But the reference source for this whole project is a .mkv, and
// AVFoundation has never supported Matroska. If that is still true, then "open the
// file the user has" is a real design problem rather than a detail — every BluRay
// rip in circulation is either MKV or MP4, and half the library would be refused.
//
// usage: vt_open_probe FILE [FILE...]

func describe(_ url: URL) {
    print("=== \(url.lastPathComponent) ===")
    let asset = AVURLAsset(url: url)

    let semaphore = DispatchSemaphore(value: 0)
    var loaded = false
    Task {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            loaded = !tracks.isEmpty
        } catch {
            print("  loadTracks threw: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()

    guard loaded else {
        print("  VERDICT: no video track available")
        return
    }

    let semaphore2 = DispatchSemaphore(value: 0)
    Task {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                print("  no track")
                semaphore2.signal()
                return
            }
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            let minDuration = try await track.load(.minFrameDuration)
            let descriptions = try await track.load(.formatDescriptions)

            print("  size            \(Int(size.width))x\(Int(size.height))")
            print("  nominalFrameRate \(rate)")
            // The exact rational: for film this is 1001/24000, which is why it is
            // read here rather than recovered from the float above.
            print("  minFrameDuration \(minDuration.value)/\(minDuration.timescale)"
                  + "  -> \(minDuration.timescale)/\(minDuration.value)")
            for description in descriptions {
                let subType = CMFormatDescriptionGetMediaSubType(description)
                let fourCC = String(bytes: [
                    UInt8((subType >> 24) & 0xFF), UInt8((subType >> 16) & 0xFF),
                    UInt8((subType >> 8) & 0xFF), UInt8(subType & 0xFF),
                ], encoding: .ascii) ?? "????"
                print("  codec           \(fourCC)")

                if let extensions = CMFormatDescriptionGetExtensions(description)
                    as? [String: Any] {
                    let keys = [
                        kCMFormatDescriptionExtension_ColorPrimaries,
                        kCMFormatDescriptionExtension_TransferFunction,
                        kCMFormatDescriptionExtension_YCbCrMatrix,
                        kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
                        kCMFormatDescriptionExtension_ContentLightLevelInfo,
                    ]
                    for key in keys {
                        let name = (key as String).replacingOccurrences(
                            of: "CMFormatDescriptionExtension_", with: "")
                        if let value = extensions[key as String] {
                            if let data = value as? Data {
                                print("  \(name): \(data.count) bytes")
                            } else {
                                print("  \(name): \(value)")
                            }
                        } else {
                            print("  \(name): (absent)")
                        }
                    }
                }
            }

            // The real test: can a reader be created and started?
            do {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    ])
                guard reader.canAdd(output) else {
                    print("  VERDICT: reader refused the track output")
                    semaphore2.signal()
                    return
                }
                reader.add(output)
                guard reader.startReading() else {
                    print("  VERDICT: startReading failed: "
                          + "\(reader.error?.localizedDescription ?? "no error")")
                    semaphore2.signal()
                    return
                }
                if let sample = output.copyNextSampleBuffer() {
                    let buffer = CMSampleBufferGetImageBuffer(sample)
                    let format = buffer.map { CVPixelBufferGetPixelFormatType($0) } ?? 0
                    let w = buffer.map { CVPixelBufferGetWidth($0) } ?? 0
                    let h = buffer.map { CVPixelBufferGetHeight($0) } ?? 0
                    print("  first frame     \(w)x\(h) pixelFormat 0x"
                          + String(format: "%08X", format))
                    print("  VERDICT: readable")
                } else {
                    print("  VERDICT: startReading succeeded but produced no frame")
                }
                reader.cancelReading()
            } catch {
                print("  VERDICT: AVAssetReader init failed: \(error.localizedDescription)")
            }
        } catch {
            print("  load failed: \(error.localizedDescription)")
        }
        semaphore2.signal()
    }
    semaphore2.wait()
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write("usage: vt_open_probe FILE [FILE...]\n".data(using: .utf8)!)
    exit(2)
}
for path in paths {
    describe(URL(fileURLWithPath: path))
    print("")
}
