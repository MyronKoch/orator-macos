import AVFoundation
import Foundation
import PhononTTS

// Usage: PhononSmoke <models-dir> <out.wav> [voice]
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: PhononSmoke <models-dir> <out.wav> [voice]"); exit(2) }
let models = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let text = "The meeting moved to 7:42 on Thursday, and the coffee cost $3.75. Siobhan Okonkwo signed off on commit ea919c6. Can you believe it actually worked the first time?"

let t0 = Date()
print("needs compiling:", Phonon.needsCompiling(models))
let tts = try await Phonon.load(models: models, language: .english)
print(String(format: "loaded in %.2fs; %d voices", Date().timeIntervalSince(t0), tts.voices.count))
print("voices:", tts.voices.prefix(12).joined(separator: ", "))
if args.count >= 4 { try await tts.setVoice(args[3]) }
print("voice:", tts.voice)

let t1 = Date()
let samples = try await tts.synthesize(text)
let seconds = Double(samples.count) / Phonon.sampleRate
print(String(format: "synthesized %.2fs of audio in %.2fs (%.1fx realtime)", seconds, Date().timeIntervalSince(t1), seconds / Date().timeIntervalSince(t1)))

let format = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!
let file = try AVAudioFile(forWriting: out, settings: format.settings)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
buffer.frameLength = buffer.frameCapacity
samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
try file.write(from: buffer)
print("wrote", out.path)
