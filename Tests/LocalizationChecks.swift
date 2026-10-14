import Foundation

@main struct LocalizationChecks {
    static func main() throws {
        var checks=0
        let suite=ProcessInfo.processInfo.environment["VECTA_VERIFICATION_PREFERENCES"]!
        precondition(suite.hasPrefix("Vecta.Verification.Localization."))
        let defaults=VL.preferences
        defer {defaults.removePersistentDomain(forName:suite)}
        precondition(VectaLanguage.preferred(in:defaults) == .english);checks+=1
        defaults.set("unsupported",forKey:"Vecta.interfaceLanguage")
        precondition(VectaLanguage.preferred(in:defaults) == .english);checks+=1
        for language in VectaLanguage.allCases {
            defaults.set(language.rawValue,forKey:"Vecta.interfaceLanguage")
            precondition(VectaLanguage.preferred(in:defaults) == language);checks+=1
            let decoded=try JSONDecoder().decode(VectaLanguage.self,from:JSONEncoder().encode(language))
            precondition(decoded == language);checks+=1
        }
        let url=URL(fileURLWithPath:ProcessInfo.processInfo.environment["VECTA_TEST_CATALOG"]!)
        let catalog=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
        precondition(catalog.count>=996);checks+=1
        for (key,translation) in catalog {
            let count=key.components(separatedBy:"%@").count-1
            precondition(translation.components(separatedBy:"%@").count-1 == count);checks+=1
            precondition(!translation.isEmpty);checks+=1
            let arguments=(0..<count).map {"literal-\($0)-%@-Русский"}
            let english=VL.render(key:key,arguments:arguments,language:.english)
            let russian=VL.render(key:key,arguments:arguments,language:.russian)
            if count==0 {
                precondition(english==translation && russian==key)
            } else {
                let enParts=translation.components(separatedBy:"%@")
                let ruParts=key.components(separatedBy:"%@")
                let expectedEnglish=arguments.enumerated().reduce(enParts[0]) {$0+$1.element+enParts[$1.offset+1]}
                let expectedRussian=arguments.enumerated().reduce(ruParts[0]) {$0+$1.element+ruParts[$1.offset+1]}
                precondition(english==expectedEnglish && russian==expectedRussian)
            }
            checks+=1
        }
        precondition(VL.render(key:"unknown %@",arguments:["100% %@"],language:.english)=="unknown 100% %@");checks+=1
        precondition(VL.render(key:"unknown %@",arguments:["one","two"],language:.english)=="unknown %@");checks+=1
        defaults.removeObject(forKey:"Vecta.interfaceLanguage")
        let language=VL.language
        precondition(language == .english);checks+=1
        defaults.set("ru",forKey:"Vecta.interfaceLanguage")
        precondition(VL.language==language);checks+=1
        precondition(VL.text("Настройки")==catalog["Настройки"]);checks+=1
        let base=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.wav",
            audioSHA256:String(repeating:"a",count:64),provider:.local,format:VectaSummaryInterpretation.allCases[0],
            createdAt:Date(timeIntervalSince1970:0),summaryOnly:false,transcriptRequestID:nil)
        let output=URL(fileURLWithPath:"/synthetic/results/output.json")
        var paths=Set<URL>()
        for snapshot:String? in [nil,"en","ru"] {
            var request=base;request.outputLanguage=snapshot
            try request.validate()
            let encoded=try JSONEncoder().encode(request)
            let decoded=try JSONDecoder().decode(AIProcessingRequest.self,from:encoded)
            precondition(decoded==request && decoded.format==base.format);checks+=1
            precondition(decoded.outputLanguage==snapshot);checks+=1
            let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            precondition(snapshot != nil || object["outputLanguage"]==nil);checks+=1
            precondition(request.resultLanguage == (snapshot=="en" ? .english:.russian));checks+=1
            let path=request.speechCheckpointURL(for:output)
            paths.insert(path)
            precondition(path.deletingLastPathComponent()==output.deletingLastPathComponent());checks+=1
            precondition(request.acceptsSpeechCheckpoint(version:request.speechCheckpointVersion,outputLanguage:snapshot,decodingPolicy:request.speechDecodingPolicy));checks+=1
            precondition(!request.acceptsSpeechCheckpoint(version:99,outputLanguage:snapshot,decodingPolicy:request.speechDecodingPolicy));checks+=1
            precondition(!request.acceptsSpeechCheckpoint(version:request.speechCheckpointVersion,outputLanguage:snapshot,decodingPolicy:"wrong-policy"));checks+=1
            for other:String? in [nil,"en","ru"] where other != snapshot {
                precondition(!request.acceptsSpeechCheckpoint(version:request.speechCheckpointVersion,outputLanguage:other,decodingPolicy:request.speechDecodingPolicy));checks+=1
            }
        }
        precondition(paths.count==3);checks+=1
        precondition(base.speechCheckpointURL(for:output).lastPathComponent=="speech-v1-"+base.audioSHA256+".json");checks+=1
        precondition(base.acceptsSpeechCheckpoint(version:1,outputLanguage:nil,decodingPolicy:nil));checks+=1
        var invalid=base;invalid.outputLanguage="unsupported"
        do {try invalid.validate();preconditionFailure("Invalid language accepted")} catch {checks+=1}
        print("PASS \(checks) localization/request checks: default English, preferences, catalog rendering, literal interpolation, historical request preservation and isolated speech checkpoint identities. No production preferences or user data accessed.")
    }
}
