import AppKit
import SwiftUI

@MainActor extension NativeMacModel {
    var canRestartForLanguage:Bool {
        !macRecorder.busy && !busy && !importingAudio && !chatBusy && !libraryQuestionBusy && !requestingAnalysis && !visualRetryBusy &&
        !analysisBusy && !batchChecking && batchActiveRequest == nil &&
        !scanning && !languageRestarting && localAI?.activeRequest == nil &&
        localAI?.installingSpeech != true && localAI?.removingSpeech != true &&
        localAI?.statuses.values.contains(where:{[.preparing,.downloading,.deleting].contains($0.state)}) != true
    }
    func restartForLanguage(_ language:VectaLanguage) {
        guard let delegate=NSApp.delegate as? NativeMacDelegate else{return}
        delegate.restartForLanguage(language)
    }
}

/// The helper opens a new instance only after the old process has exited normally.
enum NativeLanguageRestart {
    static func helper(bundle:URL,pid:Int32,arguments:[String],environment:[String:String])->Process {
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/bin/sh")
        process.arguments=["-c","pid=$1; bundle=$2; shift 2; n=0; while kill -0 \"$pid\" 2>/dev/null; do n=$((n+1)); [ \"$n\" -lt 600 ] || exit 3; sleep 0.1; done; exec /usr/bin/open -n \"$bundle\" --args \"$@\"","Vecta-language-restart",String(pid),bundle.path]+arguments
        var environment=environment;environment["VECTA_TEST_LANGUAGE"]=nil
        process.environment=environment
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        return process
    }
}

struct NativeAppRoot:View {
    @ObservedObject var model:NativeMacModel
    @State private var welcomed:Bool
    init(model:NativeMacModel) {
        self.model=model
        let verifying=VectaRuntimePreferences.isVerification && !CommandLine.arguments.contains("--verify-welcome")
        _welcomed=State(initialValue:verifying || VL.preferences.bool(forKey:"Vecta.welcomeCompleted"))
    }
    var body:some View {
        Group {
            if welcomed {NativeMacView(model:model)}
            else {NativeWelcomeScreen(model:model) {
                VL.preferences.set(true,forKey:"Vecta.welcomeCompleted");welcomed=true
            }}
        }.environment(\.locale,VL.locale).vectaFocusStyle()
    }
}

struct NativeWelcomeScreen:View {
    @ObservedObject var model:NativeMacModel
    let continueAction:()->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Image(systemName:"waveform.circle.fill").font(.system(size:56)).foregroundColor(Ink.text)
                Text(VL.text("Добро пожаловать в Vecta")).font(.system(size:32,weight:.bold))
                Text(VL.text("Ваши записи. Ваш Mac. Ваш язык.")).font(.system(size:20,weight:.medium))
                Text(VL.text("Сохраняйте записи с PLAUD, расшифровывайте речь и создавайте саммари локально на Mac. Записи и результаты не отправляются в облако."))
                    .font(.system(size:14)).foregroundColor(Ink.secondary).lineSpacing(5)
                Text(VL.text("Модели устанавливаются только по вашему запросу. Подключение диктофона настраивается отдельно."))
                    .font(.system(size:12)).foregroundColor(Ink.secondary)
                Button(VL.text("Начать работу"),action:continueAction).buttonStyle(QuietButton(primary:true)).disabled(model.languageRestarting)
            }.frame(maxWidth:640,alignment:.leading).padding(40).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)
        }.background(Ink.canvas).foregroundColor(Ink.text).frame(minWidth:760,minHeight:560)
    }
}
