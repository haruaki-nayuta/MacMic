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

func getDeviceName(_ deviceID: AudioObjectID) -> String {
    var name: CFString = "" as CFString
    var propertySize = UInt32(MemoryLayout<CFString>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    let status = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, ptr)
    }
    
    return status == noErr ? (name as String) : "Unknown Device"
}


// MARK: - Ring Buffer
// 簡易的なSRSW (Single Reader Single Writer) リングバッファ
class RingBuffer {
    var buffer: UnsafeMutablePointer<Float32>
    var capacity: UInt32
    var writeIndex: UInt32 = 0
    var readIndex: UInt32 = 0
    
    // Interactive State
    var volume: Float32 = 1.0
    var isMuted: Bool = false
    
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
        for i in 0..<count {
            buffer[Int(writeIndex % capacity)] = data[Int(i)]
            writeIndex &+= 1 // オーバーフロー許容の加算
        }
    }
    
    // データ読み出し (Output Callbackから呼ばれる)
    func read(_ data: UnsafeMutablePointer<Float32>, count: UInt32) {
        // Mute check
        if isMuted {
            data.initialize(repeating: 0, count: Int(count))
            // ポインターだけは進めておく（じゃないと解除時に古い音が再生される可能性があるため）
            // ただ、Hardcore仕様ならそのままReadIndexも進めるのが自然
            let available = Int(writeIndex) - Int(readIndex)
            if available >= count {
                 readIndex &+= count
            } else {
                 readIndex = writeIndex // 最新に合わせる
            }
            return
        }

        let available = Int(writeIndex) - Int(readIndex)
        
        // アンダーフロー対策
        if available < count {
            data.initialize(repeating: 0, count: Int(count))
            return 
        }
        
        // オーバーフロー(遅れすぎ)対策
        if available > Int(capacity) {
             readIndex = writeIndex - capacity
        }
        
        // catch-up logic
        if available > Int(count * 2) {
             let skip = available - Int(count)
             readIndex &+= UInt32(skip)
        }
        
        // Copy and Apply Volume
        let vol = volume
        for i in 0..<count {
            let sample = buffer[Int(readIndex % capacity)]
            data[Int(i)] = sample * vol
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
    
    let audioUnit = inRefCon.assumingMemoryBound(to: AudioUnit.Pointee.self)
    
    var buffer = AudioBufferList()
    buffer.mNumberBuffers = 1
    
    var data = [Float32](repeating: 0, count: Int(inNumberFrames))
    
    data.withUnsafeMutableBufferPointer { ptr in
        buffer.mBuffers.mNumberChannels = 1
        buffer.mBuffers.mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float32>.size)
        buffer.mBuffers.mData = UnsafeMutableRawPointer(ptr.baseAddress)
        
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            kInputBus,
            inNumberFrames,
            &buffer
        )
        
        if status == noErr, let baseAddr = ptr.baseAddress {
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
    
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    
    if let buf = buffers.first, let ptr = buf.mData?.assumingMemoryBound(to: Float32.self) {
        ringBuffer.read(ptr, count: inNumberFrames)
    }
    
    return noErr
}

// MARK: - Terminal Utils
struct Terminal {
    static var originalTermios = termios()
    
    static func enableRawMode() {
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        // Disable ECHO and ICANON (canonical mode)
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }
    
    static func disableRawMode() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }
    
    static func readChar() -> UInt8? {
        var char: UInt8 = 0
        let n = read(STDIN_FILENO, &char, 1)
        if n > 0 {
            return char
        }
        return nil
    }
}


func main() {
    let kAppVersion = "1.0.0"
    let args = CommandLine.arguments

    // Check for Help
    if args.contains("-h") || args.contains("--help") {
        print("""
        Usage: MacMic [options]

        Options:
          -b <size>  Set buffer size (32, 64, 128, 256). Default: 32.
          -v         Show version information.
          -h         Show this help message.
        """)
        exit(0)
    }

    // Check for Version
    if args.contains("-v") || args.contains("--version") {
        print("MacMic version \(kAppVersion)")
        exit(0)
    }

    // Default buffer size
    var bufferFrames: UInt32 = 32
    
    // Parse command line arguments for buffer size
    if let index = args.firstIndex(of: "-b") {
        if index + 1 < args.count {
            if let val = UInt32(args[index + 1]) {
                if [32, 64, 128, 256].contains(val) {
                    bufferFrames = val
                } else {
                    print("Error: Invalid buffer size. Please choose from 32, 64, 128, 256.")
                    exit(1)
                }
            } else {
                print("Error: Invalid integer format for buffer size.")
                exit(1)
            }
        } else {
            print("Error: Missing value for -b option.")
            exit(1)
        }
    }

    print("\n⚡️ Vibe Mic Hardcore v2: Dueal-Unit Engine ⚡️")
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
    
    var one: UInt32 = 1
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &one, 4), "Enable Input IO")
    var zero: UInt32 = 0
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &zero, 4), "Disable Input Unit Output")
    
    var inputDeviceID = AudioObjectID(0)
    var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &inputDeviceID), "Get Default Input Device")
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDeviceID, 4), "Set Input Device")
    print("   🎤 Input Device: \(getDeviceName(inputDeviceID))")

    
    // ---------------------------------------------------------
    // 2. Create Output Unit (HALOutput, Output enabled)
    // ---------------------------------------------------------
    checkErr(AudioComponentInstanceNew(comp!, &outputUnit), "New Output Unit")
    
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &zero, 4), "Disable Output Unit Input")
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &one, 4), "Enable Output IO")
    
    var outputDeviceID = AudioObjectID(0)
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice
    checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &outputDeviceID), "Get Default Output Device")
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputDeviceID, 4), "Set Output Device")
    print("   🔊 Output Device: \(getDeviceName(outputDeviceID))")

    
    // ---------------------------------------------------------
    // 3. Format Setup
    // ---------------------------------------------------------
    var deviceFormat = AudioStreamBasicDescription()
    var deviceFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    checkErr(AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &deviceFormat, &deviceFormatSize), "Get Device Format")
    
    let sampleRate = deviceFormat.mSampleRate
    print("   ℹ️ Device Sample Rate: \(sampleRate) Hz")

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
    
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &streamFormat, formatSize), "Set Input Format")
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &streamFormat, formatSize), "Set Output Format")

    
    // ---------------------------------------------------------
    // 4. Callbacks
    // ---------------------------------------------------------
    var inputCallbackStruct = AURenderCallbackStruct(
        inputProc: inputRenderCallback,
        inputProcRefCon: UnsafeMutableRawPointer(inputUnit!)
    )
    checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set Input Callback")
    
    var outputCallbackStruct = AURenderCallbackStruct(
        inputProc: outputRenderCallback,
        inputProcRefCon: nil
    )
    checkErr(AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &outputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set Output Callback")


    // ---------------------------------------------------------
    // 5. Buffer Size (Extreme Optimization)
    // ---------------------------------------------------------
    let uint32Size = UInt32(MemoryLayout<UInt32>.size)
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
    
    print("\n   -----------------------------------------")
    print("   [q] Quit  [m] Mute  [↑] Vol+  [↓] Vol-")
    print("   -----------------------------------------")

    // ---------------------------------------------------------
    // 7. Interactive Loop
    // ---------------------------------------------------------
    Terminal.enableRawMode()
    defer { Terminal.disableRawMode() } // Ensure we restore terminal
    
    // Initial Status Print
    func printStatus() {
        let volPercent = Int(ringBuffer.volume * 100)
        let muteStatus = ringBuffer.isMuted ? "🔇 MUTED" : "🔈 ON   "
        // \r to overwrite line, \u{1B}[K to clear rest of line
        print("\r   Volume: \(volPercent)%  \(muteStatus)     ", terminator: "")
        fflush(stdout)
    }
    
    printStatus()
    
    while true {
        guard let c = Terminal.readChar() else {
            usleep(10000) // 10ms sleep to prevent 100% CPU
            continue
        }
        
        if c == 113 { // 'q'
            print("\nBye!")
            break
        } else if c == 109 { // 'm'
            ringBuffer.isMuted.toggle()
            printStatus()
        } else if c == 27 { // Escape sequence (Arrow keys)
            // Expecting [ then A or B
            guard let c2 = Terminal.readChar(), c2 == 91 else { continue }
            guard let c3 = Terminal.readChar() else { continue }
            
            if c3 == 65 { // Up Arrow
                ringBuffer.volume = min(ringBuffer.volume + 0.1, 2.0) // Max 200%
                printStatus()
            } else if c3 == 66 { // Down Arrow
                ringBuffer.volume = max(ringBuffer.volume - 0.1, 0.0)
                printStatus()
            }
        }
    }
    
    checkErr(AudioOutputUnitStop(inputUnit!), "Stop Input")
    checkErr(AudioOutputUnitStop(outputUnit!), "Stop Output")
    
    AudioComponentInstanceDispose(inputUnit!)
    AudioComponentInstanceDispose(outputUnit!)
}

main()