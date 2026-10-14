import AppKit
import SwiftUI

struct NativeProcessingProgress:View {
    private func activity(_ state:AIWorkProgress)->String {
        guard state.stage == .summarizing else {return state.stage.title}
        switch state.workerPhase {
        case "facts":return VL.text("Извлекаем основные мысли")
        case "reduce":return VL.text("Объединяем результаты")
        case "final":return VL.text("Создаём саммари")
        default:return state.stage.title
        }
    }
    @ObservedObject var host:LocalAIHost
    let id:UUID
    var body:some View {
        if let state=host.processingProgress[id] {
            VStack(alignment:.leading,spacing:10) {
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(activity(state)).font(.system(size:13,weight:.medium)).foregroundColor(Ink.text).lineLimit(2)
                    Spacer(minLength:8)
                    Text((state.weightedEstimate ? "≈ ":"")+"\(Int(state.fraction*100)) %")
                        .font(.system(size:13,weight:.medium)).monospacedDigit().foregroundColor(Ink.text)
                }
                ProgressView(value:state.fraction).tint(Ink.text)
                    .accessibilityLabel(VL.text("Общий прогресс обработки"))
                    .accessibilityValue(VL.text("\(Int(state.fraction*100)) процентов"))
            }.padding(.vertical,8)
        }
    }
}


struct NativeAutomaticFormats:View {
    @ObservedObject var model:NativeMacModel
    private var recipes:[NativeSummaryRecipe] {NativeSummarySelection.recipes(formats:model.formats,templates:model.workspace.templates)}
    var body:some View {
        if let host=model.localAI {
            VStack(alignment:.leading,spacing:14) {
                HStack(alignment:.firstTextBaseline,spacing:16) {
                    Text(VL.text("Формат саммари")).frame(maxWidth:.infinity,alignment:.leading)
                    Picker(VL.text("Формат автоматического саммари"),selection:selection(host)) {
                        ForEach(recipes) {Text($0.title).tag($0.id)}
                    }.labelsHidden().frame(width:200)
                }
                Toggle(VL.text("Создавать визуальное саммари"),isOn:Binding(get:{host.automaticSettings.visual},set:{var value=host.automaticSettings;value.visual=$0;host.setAutomaticSettings(value)})).toggleStyle(.checkbox)
                Text(VL.text("Текстовое саммари и инфографика создаются в одном выбранном формате.")).font(.system(size:12)).foregroundColor(Ink.secondary).lineSpacing(4)
            }.disabled(!model.automaticSummary)
        }
    }
    private func selection(_ host:LocalAIHost)->Binding<String> {
        Binding(get:{NativeSummarySelection.selected(host.automaticSettings.summaryRecipeID,legacyFormat:nil,in:recipes)?.id ?? NativeSummarySelection.defaultID},set:{id in
            var value=host.automaticSettings;value.summaryRecipeID=id;host.setAutomaticSettings(value)
        })
    }
}

struct NativePlaybackControls:View {
    let model:NativeMacModel
    @ObservedObject var playback:NativePlaybackState
    var body:some View {
                    HStack(spacing: 16) {
                        Button(action: model.togglePlayback) {
                            Group {if playback.preparing {ProgressView().controlSize(.small)} else {Image(systemName: model.playing ? "pause.fill" : "play.fill")}}.frame(width:20,height:20)
                        }
                            .buttonStyle(QuietButton(primary: true)).help(playback.preparing ? VL.text("Подготавливаю аудио…") : model.playing ? VL.text("Пауза") : VL.text("Воспроизвести")).accessibilityLabel(model.playing ? VL.text("Пауза") : VL.text("Воспроизвести"))
                        Text(clock(model.progress)).monospacedDigit().font(.system(size: 11)).foregroundColor(Ink.secondary)
                        VStack(spacing: 0) {
                            if !model.waveform.isEmpty {
                                NativeWaveformView(values: model.waveform, fraction: model.duration > 0 ? model.progress / model.duration : 0) { model.seek($0 * model.duration) }
                                    .accessibilityHidden(true)
                            }
                            // Keep the native slider in every waveform state for
                            // keyboard focus, arrow-key seeking and VoiceOver.
                            Slider(value: Binding(get: { model.progress }, set: model.seek), in: 0...max(0.1, model.duration))
                                .accessibilityLabel(VL.text("Позиция воспроизведения"))
                                .accessibilityValue(clock(model.progress) + VL.text(" из ") + clock(model.duration))
                        }
                        Text(clock(model.duration)).monospacedDigit().font(.system(size: 11)).foregroundColor(Ink.secondary)
                        VectaSelectionButton(title:String(format:"%.2g×",model.playbackRate),label:VL.text("Скорость воспроизведения")) {
                            ForEach([Float(0.75),1,1.25,1.5,2],id:\.self) {rate in Button(String(format:"%.2g×",rate)) {model.setPlaybackRate(rate)}}
                        }

                    }.padding(8).background(Ink.surface).cornerRadius(9)
    }
}

/// The affirmative name is display policy, not a learning decision.
/// Only «Да» or the chooser's explicit confirmation can enroll a voice.
struct NativeSpeakerIdentityActions:View {
    @ObservedObject var model:NativeMacModel
    let speakerID:String
    var allowsConfirmation=false
    @Binding var editingSpeaker:NativeSpeakerSelection?
    private var identity:AISpeakerIdentity? {model.resolvedConversation.identities[speakerID]}
    var body:some View {
        HStack(spacing:8) {
            Button {editingSpeaker=NativeSpeakerSelection(id:speakerID)} label:{
                Label(model.resolvedConversation.name(speakerID),systemImage:"person.crop.circle")
            }.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundColor(Ink.secondary)
                .help(VL.text("Выбрать или исправить собеседника")).accessibilityLabel(VL.text("Собеседник: ")+model.resolvedConversation.name(speakerID))
            if allowsConfirmation,let identity,identity.needsVoiceConfirmation,
               let profile=identity.suggestedProfileID,
               model.voiceLibrary.activeProfiles.contains(where:{$0.id==model.voiceLibrary.canonical(profile)}) {
                HStack(spacing:4) {
                    Button {model.confirmSpeakerMatch(speakerID)} label:{
                        Label(VL.text("Да"),systemImage:"checkmark").foregroundColor(Ink.success)
                    }.help(VL.text("Подтвердить человека и сохранить доступный образец без дубликата"))
                        .accessibilityLabel(VL.text("Да, это ")+identity.displayName+VL.text(". Подтвердить голос"))
                    Button {
                        if model.rejectSpeakerMatchForChooser(speakerID,profile:profile) {editingSpeaker=NativeSpeakerSelection(id:speakerID,rejectedProfileID:profile)}
                    } label:{Label(VL.text("Нет"),systemImage:"xmark")}
                        .help(VL.text("Отклонить совпадение и выбрать другого или нового человека"))
                        .accessibilityLabel(VL.text("Нет, это другой человек. Открыть выбор собеседника"))
                }.buttonStyle(.bordered).controlSize(.small).font(.system(size:12,weight:.medium)).fixedSize()
            }
        }
    }
}

struct NativeTranscriptRow:View {
    @ObservedObject var model:NativeMacModel
    @ObservedObject var playback:NativePlaybackState
    let segment:AISpeechSegment
    let selectingUtterances:Bool
    @Binding var selectedUtterances:Set<Int>
    @Binding var editingSpeaker:NativeSpeakerSelection?
    @Binding var wordSegment:AISpeechSegment?
    var body:some View {
                    HStack(alignment: .top, spacing: 16) {
                        Button(clock(segment.start)) { model.playExcerpt(start:segment.start,end:segment.end,segment:segment.id) }.buttonStyle(.plain).font(.system(size: 11)).monospacedDigit().foregroundColor(Ink.muted).frame(width: 42, alignment: .leading).accessibilityLabel(VL.text("Воспроизвести: ")+VectaUX.utteranceLabel(start:segment.start,speaker:segment.speaker))
                        if selectingUtterances { Toggle(VectaUX.utteranceLabel(start:segment.start,speaker:segment.speaker),isOn:Binding(get:{selectedUtterances.contains(segment.id)},set:{enabled in if enabled {selectedUtterances.insert(segment.id)}else{selectedUtterances.remove(segment.id)}})).labelsHidden().toggleStyle(.checkbox) }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {if let id=segment.resolvedSpeakerID {NativeSpeakerIdentityActions(model:model,speakerID:id,editingSpeaker:$editingSpeaker)};Spacer()}
                            transcriptText(segment).lineSpacing(4)
                        }
                    }.padding(8).background(model.progress>=segment.start && model.progress<segment.end ? Ink.elevated : Color.clear).cornerRadius(6).id(segment.id)
                    .contextMenu { if !model.words(for:segment).isEmpty {Button(VL.text("Слова и таймкоды…")) {wordSegment=segment}}; Button(VL.text("Воспроизвести реплику")) { model.playExcerpt(start:segment.start,end:segment.end,segment:segment.id) };Button(VL.text("Назначить нового собеседника")) { model.splitSpeaker([segment.id],name:VL.text("Новый собеседник")) } }
    }
    private func transcriptText(_ segment:AISpeechSegment) -> some View {
        let words=model.words(for:segment)
        var value=AttributedString(words.isEmpty ? segment.text : "")
        for (index,word) in words.enumerated() {
            var part=AttributedString(word.text)
            part.link=URL(string:"vecta-word://\(index)")
            part.foregroundColor = model.progress>=word.start && model.progress<word.end ? .white : NSColor.labelColor
            if model.progress>=word.start && model.progress<word.end { part.backgroundColor=NSColor.darkGray }
            value.append(part)
        }
        return Text(value).textSelection(.enabled)
            .onTapGesture { if words.isEmpty { model.playExcerpt(start:segment.start,end:segment.end,segment:segment.id) } }
            .environment(\.openURL,OpenURLAction { url in
                guard url.scheme=="vecta-word",let index=Int(url.host ?? ""),words.indices.contains(index) else{return .discarded}
                let word=words[index];model.playExcerpt(start:word.start,end:word.end,segment:segment.id);return .handled
            })
    }
}
