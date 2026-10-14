import Foundation

enum LibraryEvidence {
    static func hasVerifiedEvidence(_ answer:[String:Any],sources:[[String:Any]]) -> Bool {
        guard answer["schemaVersion"] as? Int==1,answer["status"] as? String=="answered",
              let paragraphs=answer["paragraphs"] as? [[String:Any]],!paragraphs.isEmpty,paragraphs.count<=12 else {return false}
        for p in paragraphs {
            guard let text=p["text"] as? String,!text.isEmpty,text.count<=3000,
                  let ids=p["sourceIDs"] as? [String],!ids.isEmpty,
                  let evidence=p["evidence"] as? [[String:Any]] else {return false}
            for id in ids {
                guard let source=sources.first(where:{$0["sourceID"] as? String==id}),let original=source["text"] as? String,
                      evidence.contains(where:{e in guard e["sourceID"] as? String==id,let quote=e["quote"] as? String,quote.count>=8 else {return false};return original.contains(quote)}) else {return false}
            }
        }
        return true
    }
    static func fallback(paragraphs:[[String:Any]],sources:[[String:Any]]) -> [String:Any]? {
        // Fallback is literal evidence, never an unreviewed paraphrase.
        var quotes=[[String:Any]](),seen=Set<String>()
        for paragraph in paragraphs {
                    guard let evidence=paragraph["evidence"] as? [[String:Any]],let ids=paragraph["sourceIDs"] as? [String] else {continue}
                    for entry in evidence {
                        guard let id=entry["sourceID"] as? String,ids.contains(id),let quote=entry["quote"] as? String,
                              quote.count>=8,quote.count<=1200,let source=sources.first(where:{$0["sourceID"] as? String==id}),
                              let original=source["text"] as? String,original.contains(quote),seen.insert(id+quote).inserted else {continue}
                        quotes.append(["text":"В записи сказано: «"+quote+"»","sourceIDs":[id]])
                    }
                }
        return quotes.isEmpty ? nil:["schemaVersion":1,"status":"answered","paragraphs":Array(quotes.prefix(8))]
    }
}
