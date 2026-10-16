import Foundation
import WhisperKit

/// GPU avoids expensive fresh-process encoder specialization for bounded work.
/// Keep the SDK's faster steady-state encoder for longer recordings.
enum VectaSpeechModelConfiguration {
    static func decodingOptions(outputLanguage:String?)->DecodingOptions {
        DecodingOptions(language:outputLanguage == nil ? "ru":nil,temperatureFallbackCount:2,
                        detectLanguage:outputLanguage == nil ? nil:true,wordTimestamps:true,concurrentWorkerCount:1)
    }
    static func usesGPUEncoder(remainingWindows:Int)->Bool {
        (1...3).contains(remainingWindows)
    }
    static func supportsWarm(remainingWindows:Int)->Bool {
        (1...32_768).contains(remainingWindows)
    }
    static func make(modelFolder:String,tokenizerFolder:URL,remainingWindows:Int)->WhisperKitConfig {
        let compute=usesGPUEncoder(remainingWindows:remainingWindows)
            ? ModelComputeOptions(audioEncoderCompute:.cpuAndGPU):ModelComputeOptions()
        return WhisperKitConfig(modelFolder:modelFolder,tokenizerFolder:tokenizerFolder,computeOptions:compute,
            verbose:false,prewarm:false,load:false,download:false)
    }
}
