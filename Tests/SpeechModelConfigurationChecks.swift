import Foundation
import CoreML
import WhisperKit

@main struct SpeechModelConfigurationChecks {
    static func main() {
        let folder="synthetic-model",tokenizer=URL(fileURLWithPath:"/synthetic-tokenizer")
        let defaults=ModelComputeOptions()
        var checks=0
        for remaining in [-1,0,1,2,3,4,20,Int.max] {
            let gpu=(1...3).contains(remaining)
            precondition(VectaSpeechModelConfiguration.usesGPUEncoder(remainingWindows:remaining)==gpu);checks+=1
            let configuration=VectaSpeechModelConfiguration.make(modelFolder:folder,tokenizerFolder:tokenizer,remainingWindows:remaining)
            precondition(configuration.modelFolder==folder && configuration.tokenizerFolder==tokenizer);checks+=1
            precondition(configuration.prewarm==false && configuration.load==false && !configuration.download);checks+=1
            precondition(configuration.computeOptions?.audioEncoderCompute==(gpu ? .cpuAndGPU:defaults.audioEncoderCompute));checks+=1
            precondition(configuration.computeOptions?.textDecoderCompute==defaults.textDecoderCompute && configuration.computeOptions?.melCompute==defaults.melCompute);checks+=1
        }
        let legacy=DecodingOptions(language:"ru",temperatureFallbackCount:2,wordTimestamps:true,concurrentWorkerCount:1)
        for snapshot:String? in [nil,"en","ru"] {
            let decoding=VectaSpeechModelConfiguration.decodingOptions(outputLanguage:snapshot)
            precondition(decoding.language == (snapshot == nil ? "ru":nil));checks+=1
            precondition(decoding.detectLanguage == (snapshot == nil ? legacy.detectLanguage:true));checks+=1
            precondition(decoding.temperatureFallbackCount==legacy.temperatureFallbackCount);checks+=1
            precondition(decoding.wordTimestamps==legacy.wordTimestamps);checks+=1
            precondition(decoding.concurrentWorkerCount==legacy.concurrentWorkerCount);checks+=1
        }
        print("PASS \(checks) speech model configuration checks: bounded GPU encoder, SDK defaults, historical forced Russian, bilingual automatic detection and unchanged decoding quality. No inference or models loaded.")
    }
}
