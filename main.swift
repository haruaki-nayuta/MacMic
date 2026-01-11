import AVFoundation
import AudioToolbox

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let outputNode = engine.outputNode

// フォーマット取得（ハードウェアのネイティブフォーマットに合わせる）
let format = inputNode.inputFormat(forBus: 0)

print("--- Vibe Audio Through ---")
print("Sample Rate: \(format.sampleRate) Hz")
print("Channels: \(format.channelCount)")

// 【重要】バッファサイズを極限まで下げる設定
// macOSではアプリ側から強制的に変更できない場合もありますが、リクエストを送ります。
// 実際には「Audio MIDI設定」アプリの設定値が優先されることが多いです。
if let audioUnit = inputNode.audioUnit {
    var bufferSize: UInt32 = 32 // 目標フレーム数 (32 frames @ 44.1kHz ≒ 0.7ms)
    let size = UInt32(MemoryLayout<UInt32>.size)
    
    let result = AudioUnitSetProperty(
        audioUnit,
        kAudioDevicePropertyBufferFrameSize,
        kAudioUnitScope_Global,
        0,
        &bufferSize,
        size
    )
    
    if result == noErr {
        print("Requested Buffer Size: \(bufferSize) frames")
    } else {
        print("Failed to set buffer size. (Using system default)")
    }
}

// 入力を出力に直結（バッファリングなしでスルー）
engine.connect(inputNode, to: outputNode, format: format)

do {
    // エンジン始動
    try engine.start()
    print("Engine started. Press Enter to quit.")
    
    // プログラムが終了しないように待機
    _ = readLine()
    
    engine.stop()
} catch {
    print("Error: \(error)")
}