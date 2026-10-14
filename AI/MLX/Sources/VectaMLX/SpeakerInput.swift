import Foundation

/// Identity labels supplied by the local host are data, never worker guesses.
/// Stable IDs remain available for attribution; tentative names retain their marker.
enum SpeakerInput {
    static func row(_ segment:[String:Any]) -> [String:Any] {
        var result:[String:Any]=["text":segment["text"] as? String ?? ""]
        if let id=segment["speakerID"] as? String {result["speakerID"]=id}
        if let name=segment["speaker"] as? String,!name.isEmpty {result["speakerName"]=name}
        return result
    }
    static func line(_ segment:[String:Any]) -> String {
        let id=segment["speakerID"] as? String ?? "Неизвестный"
        var label=id
        if let name=segment["speaker"] as? String,!name.isEmpty,
           let data=try? JSONSerialization.data(withJSONObject:["speakerName":name],options:[.sortedKeys]),
           let json=String(data:data,encoding:.utf8) {label += " "+json}
        return label+": "+(segment["text"] as? String ?? "")
    }
}
