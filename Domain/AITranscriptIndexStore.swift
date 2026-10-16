import Foundation
import SQLite3
import NaturalLanguage
import Accelerate

enum AITranscriptIndexError: Error, LocalizedError {
    case database, embeddingUnavailable
    var errorDescription:String? {switch self {case .database:return VL.text("Не удалось прочитать индекс расшифровок.");case .embeddingUnavailable:return VL.text("Смысловой индекс недоступен. Установите языковые ресурсы поиска в настройках.")}}
}

/// One actor owns the DB, embedding model and vector cache. No filesystem/history scans in search().
actor AITranscriptIndexStore {
    private var db:OpaquePointer?
    private var vectors:[Int64:[Float]]=[:]
    private var vectorDocuments:[Int64:String]=[:]
    private var vectorsLoaded=false
    private var dataVersion:Int64?
    private var encoder:AnyObject?
    private var encoderID=""
    private let embeddingLanguage:NLLanguage = VL.language == .english ? .english:.russian
    private let semanticSearch:Bool
    private var embeddingCache:[String:[Float]]=[:]
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(root:URL, semanticSearch:Bool = true) throws {
        self.semanticSearch=semanticSearch
        let folder=root.appendingPathComponent("LocalAI/LibrarySearchV1",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=folder.appendingPathComponent("index.sqlite3")
        if FileManager.default.fileExists(atPath:file.path) {
            guard try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw AITranscriptIndexError.database}
        }
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {throw AITranscriptIndexError.database}
        sqlite3_busy_timeout(db,3000)
        let schema="""
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS documents(key TEXT PRIMARY KEY, revision TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, document TEXT NOT NULL, source BLOB NOT NULL, text TEXT NOT NULL, vector BLOB, encoder TEXT);
        CREATE TABLE IF NOT EXISTS corpus_inputs(key TEXT PRIMARY KEY,stamp TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS chunk_document ON chunks(document);
        CREATE VIRTUAL TABLE IF NOT EXISTS text_index USING fts5(text, tokenize='unicode61 remove_diacritics 2');
        """
        guard sqlite3_exec(db,schema,nil,nil,nil)==SQLITE_OK else {throw AITranscriptIndexError.database}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    deinit {sqlite3_close(db)}
    private func statement(_ sql:String) throws -> OpaquePointer {
        var p:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&p,nil)==SQLITE_OK,let p else {throw AITranscriptIndexError.database};return p
    }
    private func bind(_ text:String,_ p:OpaquePointer,_ index:Int32) {sqlite3_bind_text(p,index,text,-1,transient)}
    private func exec(_ sql:String) throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw AITranscriptIndexError.database}}
    func revisions() throws -> [String:String] {
        let p=try statement("SELECT key,revision FROM documents");defer{sqlite3_finalize(p)}
        var values=[String:String]();while sqlite3_step(p)==SQLITE_ROW {values[String(cString:sqlite3_column_text(p,0))]=String(cString:sqlite3_column_text(p,1))};return values
    }
    func inputs() throws -> [String:String] {
        let p=try statement("SELECT key,stamp FROM corpus_inputs WHERE key IN (SELECT document FROM chunks GROUP BY document HAVING count(vector)=count(*))")
        defer{sqlite3_finalize(p)};var values=[String:String]()
        while sqlite3_step(p)==SQLITE_ROW {values[String(cString:sqlite3_column_text(p,0))]=String(cString:sqlite3_column_text(p,1))};return values
    }
    func setInput(_ key:String,stamp:String) throws {
        let p=try statement("INSERT OR REPLACE INTO corpus_inputs VALUES(?,?)");defer{sqlite3_finalize(p)};bind(key,p,1);bind(stamp,p,2)
        guard sqlite3_step(p)==SQLITE_DONE else{throw AITranscriptIndexError.database}
    }
    func status() throws -> AILibraryIndexStatus {
        let p=try statement("SELECT (SELECT count(*) FROM documents),count(*),count(vector) FROM chunks");defer{sqlite3_finalize(p)}
        guard sqlite3_step(p)==SQLITE_ROW else {throw AITranscriptIndexError.database}
        return AILibraryIndexStatus(recordings:Int(sqlite3_column_int(p,0)),chunks:Int(sqlite3_column_int(p,1)),semanticChunks:Int(sqlite3_column_int(p,2)))
    }
    func retain(_ keys:Set<String>) throws {
        for key in try revisions().keys where !keys.contains(key) {try remove(key)}
    }
    func erase(_ key:String) throws {
        try exec("PRAGMA secure_delete=ON")
        try exec("BEGIN IMMEDIATE")
        do { try remove(key); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
        embeddingCache.removeAll()
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    private func remove(_ key:String) throws {
        let p=try statement("SELECT id FROM chunks WHERE document=?");bind(key,p,1)
        var ids=[Int64]();while sqlite3_step(p)==SQLITE_ROW {ids.append(sqlite3_column_int64(p,0))};sqlite3_finalize(p)
        for id in ids {try exec("DELETE FROM text_index WHERE rowid=\(id)");vectors[id]=nil;vectorDocuments[id]=nil}
        for sql in ["DELETE FROM chunks WHERE document=?","DELETE FROM documents WHERE key=?","DELETE FROM corpus_inputs WHERE key=?"] {let p=try statement(sql);defer{sqlite3_finalize(p)};bind(key,p,1);guard sqlite3_step(p)==SQLITE_DONE else {throw AITranscriptIndexError.database}}
    }
    private func embedding(_ text:String) throws -> [Float]? {
        if let cached=embeddingCache[text] {return cached}
        guard semanticSearch, #available(macOS 14.0,*) else {return nil}
        if encoder==nil {
            guard let e=NLContextualEmbedding(language:embeddingLanguage),e.hasAvailableAssets else {return nil}
            try e.load();encoder=e;encoderID=e.modelIdentifier
        }
        guard let e=encoder as? NLContextualEmbedding else {return nil}
        let body=String(text.prefix(2000));guard !body.isEmpty else {return nil}
        let result=try e.embeddingResult(for:body,language:embeddingLanguage)
        var vector=[Float](repeating:0,count:e.dimension)
        result.enumerateTokenVectors(in:body.startIndex..<body.endIndex) {v,_ in for i in vector.indices {vector[i]+=Float(v[i])};return true}
        let norm=sqrt(vector.reduce(0){$0+$1*$1});guard norm.isFinite,norm>0 else {return nil};let normalized=vector.map{$0/norm}
        if embeddingCache.count>=256 {embeddingCache.removeAll(keepingCapacity:true)};embeddingCache[text]=normalized;return normalized
    }
    func replace(_ document:AILibraryDocument) throws {
        try Task.checkCancellation()
        let existing=try statement("SELECT revision FROM documents WHERE key=?");bind(document.key,existing,1)
        let unchanged=sqlite3_step(existing)==SQLITE_ROW && String(cString:sqlite3_column_text(existing,0))==document.revision
        sqlite3_finalize(existing)
        if unchanged {
            let missing=try statement("SELECT count(*) FROM chunks WHERE document=? AND vector IS NULL");bind(document.key,missing,1)
            let backfill=sqlite3_step(missing)==SQLITE_ROW && sqlite3_column_int(missing,0)>0
            sqlite3_finalize(missing)
            if !backfill {return}
            guard #available(macOS 14.0,*),NLContextualEmbedding(language:embeddingLanguage)?.hasAvailableAssets==true else {return}
        }
        // Compute outside the transaction: cancellation leaves the previous revision usable.
        var prepared=[(AILibrarySource,[Float]?)]()
        for source in document.sources {try Task.checkCancellation();prepared.append((source,try? embedding(source.text)))}
        try Task.checkCancellation()
        try exec("BEGIN IMMEDIATE")
        do {
            try remove(document.key)
            let doc=try statement("INSERT INTO documents VALUES(?,?)");defer{sqlite3_finalize(doc)};bind(document.key,doc,1);bind(document.revision,doc,2)
            guard sqlite3_step(doc)==SQLITE_DONE else {throw AITranscriptIndexError.database}
            for (source,vector) in prepared {
                let p=try statement("INSERT INTO chunks(document,source,text,vector,encoder) VALUES(?,?,?,?,?)");defer{sqlite3_finalize(p)}
                let bytes=try JSONEncoder().encode(source);bind(document.key,p,1)
                _=bytes.withUnsafeBytes{sqlite3_bind_blob(p,2,$0.baseAddress,Int32(bytes.count),transient)}
                bind(Self.normalizedSearchText(source.title+" "+source.text),p,3)
                if let vector {_=vector.withUnsafeBytes{sqlite3_bind_blob(p,4,$0.baseAddress,Int32($0.count),transient)};bind(encoderID,p,5)}
                guard sqlite3_step(p)==SQLITE_DONE else {throw AITranscriptIndexError.database}
                let id=sqlite3_last_insert_rowid(db)
                let f=try statement("INSERT INTO text_index(rowid,text) VALUES(?,?)");defer{sqlite3_finalize(f)};sqlite3_bind_int64(f,1,id);bind(Self.normalizedSearchText(source.title+" "+source.text),f,2)
                guard sqlite3_step(f)==SQLITE_DONE else {throw AITranscriptIndexError.database}
                if let vector {vectors[id]=vector;vectorDocuments[id]=document.key}
            }
            try exec("COMMIT")
        } catch {try? exec("ROLLBACK");vectors=[:];vectorDocuments=[:];vectorsLoaded=false;throw error}
    }
    private func loadVectors() throws {
        guard !vectorsLoaded else {return};vectors=[:];vectorDocuments=[:]
        let p=try statement("SELECT id,document,vector FROM chunks WHERE vector IS NOT NULL AND encoder=?");defer{sqlite3_finalize(p)};bind(encoderID,p,1)
        while sqlite3_step(p)==SQLITE_ROW {
            guard let bytes=sqlite3_column_blob(p,2) else {continue};let count=Int(sqlite3_column_bytes(p,2))/MemoryLayout<Float>.size
            let id=sqlite3_column_int64(p,0)
            let data=Data(bytes:bytes,count:count*MemoryLayout<Float>.size)
            vectors[id]=data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))};vectorDocuments[id]=String(cString:sqlite3_column_text(p,1))
        }
        vectorsLoaded=true
    }
    static func normalizedSearchText(_ text:String) -> String {
        text.lowercased().replacingOccurrences(of:"ё",with:"е")
    }
    static func lexicalQuery(_ question:String) -> String {
        let ignored=Set(["что","чем","как","где","когда","какие","какой","было","были","мне","все","всех","записи","записям","расскажи","пожалуйста","для","про","при","это","его","она","они","нам","нас","мои","моих","своих","говорил","говорили","сказал","сказали","рассказывал","обсуждали","упоминал","упоминали","узнать","поводу","договорились","решили","what","when","where","which","about","with","have","were","did","the","and","our","please"])
        let words=normalizedSearchText(question).components(separatedBy:CharacterSet.alphanumerics.inverted)
        var seen=Set<String>(),terms=[String]()
        for word in words where word.count>2 && !ignored.contains(word) && seen.insert(word).inserted {
            var stem=word
            let cyrillic=word.unicodeScalars.allSatisfy({(0x430...0x44f).contains($0.value)})
            if cyrillic {
                for suffix in ["иями","ями","ами","ого","ему","ому","ыми","ими","иях","ах","ях","ой","ей","ую","юю","ая","яя","ое","ее","ые","ие","ов","ев","ам","ям","ом","ем","ы","и","а","я","у","ю","е"] where word.hasSuffix(suffix) && word.count-suffix.count>=3 {
                    stem=String(word.dropLast(suffix.count));break
                }
            }
            // Prefix matching tolerates Russian case endings, including proper names.
            // Only alphanumeric tokens enter the quoted FTS expression.
            terms.append("\""+stem+"\""+(cyrillic ? "*":""))
            if terms.count>=24 {break}
        }
        return terms.joined(separator:" OR ")
    }
    func search(_ question:String,visible:Set<String>,characterBudget:Int=10_000) throws -> [AILibrarySource] {
        try Task.checkCancellation()
        let version=try statement("PRAGMA data_version")
        if sqlite3_step(version)==SQLITE_ROW {
            let next=sqlite3_column_int64(version,0)
            if let prior=dataVersion,prior != next {vectorsLoaded=false}
            dataVersion=next
        }
        sqlite3_finalize(version)
        let terms=Self.lexicalQuery(question)
        var ranks=[Int64:Double]()
        if !terms.isEmpty {
            let p=try statement("SELECT text_index.rowid,chunks.document FROM text_index JOIN chunks ON chunks.id=text_index.rowid WHERE text_index MATCH ? ORDER BY bm25(text_index)");defer{sqlite3_finalize(p)};bind(terms,p,1)
            var rank=0,scanned=0
            while sqlite3_step(p)==SQLITE_ROW {
                scanned+=1;if scanned%256==0 {try Task.checkCancellation()}
                guard visible.contains(String(cString:sqlite3_column_text(p,1))) else {continue}
                rank+=1;ranks[sqlite3_column_int64(p,0)]=1/Double(30+rank)
                if rank>=80 {break}
            }
        }
        if let query=try? embedding(question) {
            try loadVectors()
            var scores=[(Int64,Float)]();scores.reserveCapacity(vectors.count)
            var iteration=0
            for (id,vector) in vectors where vector.count==query.count && visible.contains(vectorDocuments[id] ?? "") {
                iteration+=1;if iteration%256==0 {try Task.checkCancellation()}
                var score:Float=0;vDSP_dotpr(vector,1,query,1,&score,vDSP_Length(query.count));scores.append((id,score))
            }
            for (rank,pair) in Self.topScores(scores,limit:80).enumerated() {ranks[pair.0,default:0]+=1/Double(30+rank+1)}
        }
        try Task.checkCancellation()
        var selected=[AILibrarySource](),counts=[String:Int](),used=0,intervals=[String:Set<String>]()
        let best=ranks.values.max() ?? 0
        for (id,score) in ranks.sorted(by:{$0.value==$1.value ? $0.key<$1.key:$0.value>$1.value}) {
            if best>=0.04 && score<best*0.65 {continue}
            let p=try statement("SELECT source FROM chunks WHERE id=?");defer{sqlite3_finalize(p)};sqlite3_bind_int64(p,1,id)
            guard sqlite3_step(p)==SQLITE_ROW,let blob=sqlite3_column_blob(p,0) else {continue}
            var source=try JSONDecoder().decode(AILibrarySource.self,from:Data(bytes:blob,count:Int(sqlite3_column_bytes(p,0))))
            guard visible.contains(source.recordingKey),counts[source.recordingKey,default:0]<4,used+source.text.count<=characterBudget else {continue}
            if intervals[source.recordingKey,default:[]].contains(source.text) {continue}
            intervals[source.recordingKey,default:[]].insert(source.text)
            source.id="S\(selected.count+1)";selected.append(source);counts[source.recordingKey,default:0]+=1;used+=source.text.count
            if selected.count>=8 {break}
        }
        return selected
    }
    /// Bounded min-heap: preserve exact top-k without sorting the whole corpus.
    static func topScores(_ scores:[(Int64,Float)],limit:Int) -> [(Int64,Float)] {
        guard limit>0 else{return []};var heap=[(Int64,Float)]()
        func worse(_ a:(Int64,Float),_ b:(Int64,Float))->Bool {a.1==b.1 ? a.0>b.0:a.1<b.1}
        for value in scores {
            if heap.count<limit {
                heap.append(value);var i=heap.count-1
                while i>0 {let p=(i-1)/2;if !worse(heap[i],heap[p]){break};heap.swapAt(i,p);i=p}
            } else if worse(heap[0],value) {
                heap[0]=value;var i=0
                while i*2+1<heap.count {var child=i*2+1;if child+1<heap.count && worse(heap[child+1],heap[child]){child+=1};if !worse(heap[child],heap[i]){break};heap.swapAt(child,i);i=child}
            }
        }
        return heap.sorted{worse($1,$0)}
    }
    func requestAssets() async throws {
        guard #available(macOS 14.0,*),let e=NLContextualEmbedding(language:embeddingLanguage) else {throw AITranscriptIndexError.embeddingUnavailable}
        _=try await e.requestAssets()
        guard e.hasAvailableAssets else {throw AITranscriptIndexError.embeddingUnavailable}
    }
    func releaseEncoder() {if #available(macOS 14.0,*),let e=encoder as? NLContextualEmbedding {e.unload()};encoder=nil}
}
