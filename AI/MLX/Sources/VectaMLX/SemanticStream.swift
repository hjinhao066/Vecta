import Foundation

/// Decode only complete entries. A truncated string/object never becomes a card.
enum SemanticStream {
    static func snapshot(_ raw:String)->[String:Any]? {
        guard raw.utf8.count<=1_000_000,let start=raw.firstIndex(of:"{") else {return nil}
        var stack=[Character](),quoted=false,escaped=false,last:[String:Any]?
        for index in raw[start...].indices {
            let char=raw[index]
            if quoted {
                if escaped {escaped=false}
                else if char=="\\" {escaped=true}
                else if char=="\"" {quoted=false}
                continue
            }
            if char=="\"" {quoted=true;continue}
            if char=="{" || char=="[" {stack.append(char);continue}
            if char=="}" || char=="]" {
                guard stack.last == (char=="}" ? "{":"[") else {return nil}
                stack.removeLast()
                if char=="}",stack == ["{","["] {
                    let candidate=String(raw[start...index])+"]}"
                    if let bytes=candidate.data(using:.utf8),
                       var value=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
                       Worker.recoverableSemantic(value) {
                        value["sourcePolicy"]="none"
                        if let entries=value["entries"] as? [[String:Any]] {value["entries"]=entries.map {entry in var entry=entry;entry["sourceSegments"]=[Int]();return entry}}
                        last=value
                    }
                }
            }
        }
        return last
    }
}
