import Foundation

enum VectaLanguage:String,Codable,CaseIterable,Identifiable {
    case english="en",russian="ru"
    var id:String {rawValue}
    var nativeTitle:String {self == .english ? "English":"Русский"}
    /// The interface is English only. A language stored by an older build is ignored.
    static func preferred(in defaults:UserDefaults)->Self {.english}
}

/// Interpolated values are never catalog keys or format directives.
struct VectaLocalizedString:ExpressibleByStringLiteral,ExpressibleByStringInterpolation {
    let key:String
    let arguments:[String]
    init(stringLiteral value:String) {key=value;arguments=[]}
    init(stringInterpolation value:StringInterpolation) {key=value.key;arguments=value.arguments}
    struct StringInterpolation:StringInterpolationProtocol {
        var key=""
        var arguments:[String]=[]
        init(literalCapacity:Int,interpolationCount:Int) {key.reserveCapacity(literalCapacity);arguments.reserveCapacity(interpolationCount)}
        mutating func appendLiteral(_ value:String) {key += value}
        mutating func appendInterpolation<T>(_ value:T) {key += "%@";arguments.append(String(describing:value))}
        mutating func appendInterpolation<T:CVarArg>(_ value:T,specifier:String) {
            key += "%@";arguments.append(String(format:specifier,locale:VL.locale,value))
        }
    }
}

/// Language is process-scoped. Settings take effect only after orderly restart.
enum VectaLocalization {
    static let language:VectaLanguage = {
        if let value=ProcessInfo.processInfo.environment["VECTA_TEST_LANGUAGE"],let language=VectaLanguage(rawValue:value) {return language}
        return VectaLanguage.preferred(in:preferences)
    }()
    static var locale:Locale {Locale(identifier:language == .english ? "en_US":"ru_RU")}
    static var preferences:UserDefaults {
        #if VECTA_DEVELOPMENT
        if CommandLine.arguments.contains(where:{$0.hasPrefix("--verify-")}) {
            let name=ProcessInfo.processInfo.environment["VECTA_VERIFICATION_PREFERENCES"] ?? "Vecta.Verification"
            return UserDefaults(suiteName:name.hasPrefix("Vecta.Verification") ? name:"Vecta.Verification")!
        }
        #endif
        return .standard
    }
    private static let catalog:[String:String] = {
        let resources=Bundle.main.resourceURL
        let candidates=[resources?.appendingPathComponent("Localization/en.json"),
                        resources?.deletingLastPathComponent().appendingPathComponent("Localization/en.json"),
                        ProcessInfo.processInfo.environment["VECTA_TEST_CATALOG"].map {URL(fileURLWithPath:$0)}].compactMap {$0}
        for url in candidates {
            if let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode([String:String].self,from:data) {return value}
        }
        return [:]
    }()
    static func text(_ value:VectaLocalizedString)->String {render(key:value.key,arguments:value.arguments,language:language)}
    static func string(_ value:String,in language:VectaLanguage?=nil)->String {render(key:value,arguments:[],language:language ?? self.language)}
    static func render(key:String,arguments:[String],language:VectaLanguage)->String {
        let template=language == .english ? (catalog[key] ?? key):key
        guard !arguments.isEmpty else{return template}
        let parts=template.components(separatedBy:"%@")
        guard parts.count==arguments.count+1 else {return renderFallback(key,arguments:arguments)}
        return arguments.enumerated().reduce(parts[0]) {$0+$1.element+parts[$1.offset+1]}
    }
    private static func renderFallback(_ key:String,arguments:[String])->String {
        let parts=key.components(separatedBy:"%@")
        guard parts.count==arguments.count+1 else{return key}
        return arguments.enumerated().reduce(parts[0]) {$0+$1.element+parts[$1.offset+1]}
    }
    static func prepareApplicationPreferences() {
        preferences.set([language.rawValue],forKey:"AppleLanguages")
        preferences.set(language == .english ? "en_US":"ru_RU",forKey:"AppleLocale")
    }
    static func bytes(_ value:Int64)->String {
        let units=language == .english ? ["B","KB","MB","GB","TB"]:["Б","КБ","МБ","ГБ","ТБ"]
        var amount=Double(max(0,value)),index=0
        while amount>=1000,index<units.count-1 {amount/=1000;index+=1}
        return amount.formatted(.number.precision(.fractionLength(index==0 ? 0:1)).locale(locale))+" "+units[index]
    }
}
typealias VL=VectaLocalization

extension Date {
    func vectaFormatted(date:Date.FormatStyle.DateStyle,time:Date.FormatStyle.TimeStyle)->String {
        formatted(Date.FormatStyle(date:date,time:time,locale:VL.locale))
    }
}
