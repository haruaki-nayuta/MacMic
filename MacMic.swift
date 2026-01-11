import AudioToolbox
import AVFoundation

// MARK: - Constants
let kInputBus: AudioUnitElement = 1
let kOutputBus: AudioUnitElement = 0
// リングバッファのサイズ (2の累乗推奨)
let kRingBufferSize: UInt32 = 4096 // 48kHzで約85ms分。遅延と安定性のトレードオフ

// MARK: - Utilities
func checkErr(_ status: OSStatus, _ message: String) {
    if status != noErr {
        print("❌ \(message) Error: \(status)")
        exit(1)
    }
}

// MARK: - Ring Buffer
// 簡易的なSRSW (Single Reader Single Writer) リングバッファ
class RingBuffer {
    var buffer: UnsafeMutablePointer<Float32>
    var capacity: UInt32
    var writeIndex: UInt32 = 0
    var readIndex: UInt32 = 0
    
    init(capacity: UInt32) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(capacity))
        // ゼロ埋め
        self.buffer.initialize(repeating: 0, count: Int(capacity))
    }
    
    deinit {
        buffer.deallocate()
    }
    
    // データ書き込み (Input Callbackから呼ばれる)
    func write(_ data: UnsafePointer<Float32>, count: UInt32) {
        // ※ 厳密な排他制御は省いています（音切れ上等のHardcore仕様）
        // 実際のプロダクションでは Atomic 変数などを使うべきです
        
        for i in 0..<count {
            buffer[Int(writeIndex % capacity)] = data[Int(i)]
            writeIndex &+= 1 // オーバーフロー許容の加算
        }
    }
    
    // データ読み出し (Output Callbackから呼ばれる)
    func read(_ data: UnsafeMutablePointer<Float32>, count: UInt32) {
        let available = Int(writeIndex) - Int(readIndex)
        
        // アンダーフロー対策: データが足りない場合はゼロ埋め（または待つ）
        if available < count {
            // 足りない分は少し待つか、無音にする。ここでは最新に追いつくように調整
            // readIndex = writeIndex - count // 最新までジャンプ（でもこれはノイズになる）
            
            // シンプルに「あるだけ読む」か、無音。
            // 完全に足りない場合は無音
            data.initialize(repeating: 0, count: Int(count))
            return 
        }
        
        // オーバーフロー(遅れすぎ)対策: 書き込みがはるか先に進んでいたら追いつく
        if available > Int(capacity) {
             readIndex = writeIndex - capacity
        }
        
        // catch-up logic:
        // if available data is too large, it means latency is accumulating.
        // We skip forward to the most recent data.
        // Keep 'count' (1 buffer) as safety margin.
        if available > Int(count * 2) {
             let skip = available - Int(count)
             readIndex &+= UInt32(skip)
             // print("⚡️ skipped \(skip)")
        }
        
        for i in 0..<count {
            data[Int(i)] = buffer[Int(readIndex % capacity)]
            readIndex &+= 1
        }
    }
}

// Global Buffer
let ringBuffer = RingBuffer(capacity: kRingBufferSize)

// MARK: - Callbacks

// Input Unit: マイクからデータが来たら呼ばれる
let inputRenderCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    ioData
) -> OSStatus in
    
    // AudioUnitはCポインタなので、Unmanagedではなく直接キャストで復元する
    // inRefConは UnsafeMutableRawPointer?
    // AudioUnitは UnsafeMutablePointer<ComponentInstanceRecord>
    let audioUnit = unsafeBitCast(inRefCon, to: AudioUnit.self)
    
    // データを確保するためのバッファリストを作成
    // ここでは1チャンネル(モノラル)前提
    var buffer = AudioBufferList()
    buffer.mNumberBuffers = 1
    
    // 一時的な受信バッファ
    var data = [Float32](repeating: 0, count: Int(inNumberFrames))
    
    data.withUnsafeMutableBufferPointer { ptr in
        buffer.mBuffers.mNumberChannels = 1
        buffer.mBuffers.mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float32>.size)
        buffer.mBuffers.mData = UnsafeMutableRawPointer(ptr.baseAddress)
        
        // Render呼び出し (データを吸い出す)
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            kInputBus,
            inNumberFrames,
            &buffer
        )
        
        if status == noErr, let baseAddr = ptr.baseAddress {
            // リングバッファへ書き込み
            ringBuffer.write(baseAddr, count: inNumberFrames)
        }
    }
    
    return noErr
}

// Output Unit: スピーカーへデータを送るために呼ばれる
let outputRenderCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    ioData
) -> OSStatus in
    
    guard let ioData = ioData else { return noErr }
    
    // ioDataのバッファにリングバッファから書き込む
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    
    if let buf = buffers.first, let ptr = buf.mData?.assumingMemoryBound(to: Float32.self) {
        // リングバッファから読み込み
        ringBuffer.read(ptr, count: inNumberFrames)
    }
    
    return noErr
}


func main() {
    print("\n⚡️ Vibe Mic Hardcore v2: Dual-Unit Engine ⚡️")
    print("   Input -> [Ring Buffer] -> Output")
    
    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?
    
    // ---------------------------------------------------------
    // 1. Create Input Unit (HALOutput, Input enabled)
    // ---------------------------------------------------------
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    
    let comp = AudioComponentFindNext(nil, &desc)
    checkErr(AudioComponentInstanceNew(comp!, &inputUnit), "New Input Unit")
    
    // Enable Input on Bus 1
    var one: UInt32 = 1
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &one, 4), "Enable Input IO")
    // Disable Output on Bus 0 (Input Unitは入力専門)
    var zero: UInt32 = 0
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &zero, 4), "Disable Input Unit Output")
    
    // Set Device: Default Input
    // InputUnitに対して現行のデフォルト入力デバイスを割り当て
    var inputDeviceID = AudioObjectID(0)
    var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &inputDeviceID), "Get Default Input Device")
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, 4), "Set Input Device")

    
    // ---------------------------------------------------------
    // 2. Create Output Unit (HALOutput, Output enabled)
    // ---------------------------------------------------------
    // 同じdescなので再利用
    checkErr(AudioComponentInstanceNew(comp!, &outputUnit), "New Output Unit")
    
    // Disable Input on Bus 1 (Output Unitは出力専門)
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &zero, 4), "Disable Output Unit Input")
    // Enable Output on Bus 0
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one, 4), "Enable Output IO")
    
    // Set Device: Default Output
    var outputDeviceID = AudioObjectID(0)
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice
    checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &outputDeviceID), "Get Default Output Device")
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputDeviceID, 4), "Set Output Device")

    
    // ---------------------------------------------------------
    // 3. Format Setup (48kHz, Float32, Mono)
    // ---------------------------------------------------------
    let sampleRate: Float64 = 48000.0
    let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
    var streamFormat = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: bytesPerSample,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerSample,
        mChannelsPerFrame: 1,
        mBitsPerChannel: bytesPerSample * 8,
        mReserved: 0
    )
    let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    
    // Input Unit Output Scope (デバイス -> Unit)
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &streamFormat, formatSize), "Set Input Format")
    // Output Unit Input Scope (Unit -> デバイス)
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &streamFormat, formatSize), "Set Output Format")

    
    // ---------------------------------------------------------
    // 4. Callbacks
    // ---------------------------------------------------------
    
    // Input Callback (データを吸い出す)
    // ※ HALOutputのInputコールバックは、Input Scopeじゃなくて Global/Output Scopeのプロパティとして設定する特殊な形... ではなく、
    //   kAudioOutputUnitProperty_SetInputCallback を使う！
    var inputCallbackStruct = AURenderCallbackStruct(
        inputProc: inputRenderCallback,
        inputProcRefCon: UnsafeMutableRawPointer(inputUnit!)
    )
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set Input Callback")
    
    // Output Callback (データを供給する)
    var outputCallbackStruct = AURenderCallbackStruct(
        inputProc: outputRenderCallback,
        inputProcRefCon: nil
    )
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &outputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set Output Callback")


    // ---------------------------------------------------------
    // 5. Buffer Size (Extreme Optimization)
    // ---------------------------------------------------------
    var bufferFrames: UInt32 = 32 // Hardcore Mode: 32 frames (approx 0.6ms)
    let uint32Size = UInt32(MemoryLayout<UInt32>.size)
    
    // 両方にリクエスト
    AudioUnitSetProperty(inputUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferFrames, uint32Size)
    AudioUnitSetProperty(outputUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferFrames, uint32Size)

    
    // ---------------------------------------------------------
    // 6. Initialize & Start
    // ---------------------------------------------------------
    checkErr(AudioUnitInitialize(inputUnit!), "Init Input")
    checkErr(AudioUnitInitialize(outputUnit!), "Init Output")
    
    checkErr(AudioOutputUnitStart(inputUnit!), "Start Input")
    checkErr(AudioOutputUnitStart(outputUnit!), "Start Output")
    
    print("   Sample Rate: \(sampleRate) Hz")
    print("   Buffer: \(bufferFrames) frames (Requested)")
    print("   🎤 Mic -> � Speaker")
    print("   [Press Enter to Quit]")
    
    _ = readLine()
    
    checkErr(AudioOutputUnitStop(inputUnit!), "Stop Input")
    checkErr(AudioOutputUnitStop(outputUnit!), "Stop Output")
    
    AudioComponentInstanceDispose(inputUnit!)
    AudioComponentInstanceDispose(outputUnit!)
}

main()