import SwiftUI

struct NativeSpeakerSelection:Identifiable {
    let id:String
    var rejectedProfileID:UUID? = nil
}

@MainActor extension NativeMacModel {
    /// A negative answer rejects only this recording's match, not the person
    /// or their history. Remove an erroneous learned source, if present, in the
    /// same atomic edit; never add a sample on this path.
    @discardableResult func rejectSpeakerMatchForChooser(_ id:String,profile:UUID)->Bool {
        guard let root=(processingRoot ?? localAI?.root)?.standardizedFileURL,voiceStateRoot==root,currentConversationRoot==root,
              let key=conversationKey,var identity=conversation.identities[id] else {
            analysisMessage=VL.text("Библиотека голосов ещё не загружена. Повторите после загрузки.");return false
        }
        do {
            var recording=conversation;var people=voiceLibrary
            let canonical=people.canonical(profile)
            identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[resolvedConversation.name(id),VL.text("Возможно, ")+resolvedConversation.name(id)])).sorted()
            recording.identities[id]=identity
            try recording.rejectMatch(id,profile:canonical)
            if identity.profileID.map(people.canonical)==canonical {
                recording.identities[id]?.profileID=nil
                recording.identities[id]?.name=identity.previousName ?? VL.text("Собеседник")
                recording.identities[id]?.origin="manual"
                recording.identities[id]?.nameOverride=false
                recording.identities[id]?.previousName=nil
            }
            let recordingID=rawAnalysis?.request.recordingID
            if let index=people.profiles.firstIndex(where:{$0.id==canonical}) {
                people.profiles[index].samples.removeAll {sample in
                    sample.speakerID==id && (sample.recordingID != nil && recordingID != nil ? sample.recordingID==recordingID:sample.recordingKey==key)
                }
            }
            try AIConversationStore(root:root).saveTogether(recording,key:key,voices:people)
            conversation=recording;voiceLibrary=people;libraryCorpusVersion+=1;analysisMessage=nil;return true
        } catch {analysisMessage=VL.text("Не удалось отклонить совпадение: ")+error.localizedDescription;return false}
    }
    @discardableResult func confirmSpeakerMatch(_ id:String)->Bool {
        guard let identity=resolvedConversation.identities[id] else{return false}
        if identity.origin=="voiceSuggestion" {return confirmSuggestedVoice(id)}
        guard let profile=identity.profileID,let person=voiceLibrary.activeProfiles.first(where:{$0.id==voiceLibrary.canonical(profile)}) else {
            analysisMessage=VL.text("Выберите собеседника, чтобы подтвердить голос.");return false
        }
        return assignSpeaker(id,name:person.name,profile:person.id,remember:false)
    }
}

/// Explicit existing-person selection and a separate new-person route. Voice
/// deletion is optional, labelled and independently confirmed.
struct NativeSpeakerSheet:View {
    @ObservedObject var model:NativeMacModel
    let speakerID:String
    var rejectedProfileID:UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var chooser=AISpeakerChooserState()
    @State private var error:String?
    private var sample:AIVoiceSample? {model.voiceSample(speakerID)}
    private var selectedPerson:AIVoiceProfile? {chooser.selectedProfileID.flatMap {id in model.voiceLibrary.activeProfiles.first {$0.id==id}}}
    private var people:[AIVoiceProfile] {chooser.people(in:model.voiceLibrary)}
    private var sampleAlreadySaved:Bool {guard let sample,let person=selectedPerson else{return false};return person.samples.contains {$0.isSameSource(as:sample)}}
    private var choice:AISpeakerChooserState.Choice? {chooser.choice(in:model.voiceLibrary,sampleAvailable:sample != nil)}
    private var deletionPerson:AIVoiceProfile? {chooser.pendingVoiceDeletion.flatMap {id in model.voiceLibrary.activeProfiles.first {$0.id==id}}}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(VL.text("Выбрать собеседника")).font(.system(size:23,weight:.semibold))
                Spacer()
                Button {dismiss()} label:{Image(systemName:"xmark").foregroundColor(Ink.secondary)}.accessibilityLabel(VL.text("Закрыть выбор собеседника")).keyboardShortcut(.cancelAction).buttonStyle(.plain)
            }
            HStack {
                Text(rejectedProfileID == nil ? VL.text("Укажите, кто говорит в этой записи."):VL.text("Совпадение отклонено. Выберите другого человека или зарегистрируйте нового.")).font(.system(size:12)).foregroundColor(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer()
                Button {
                    if let segment=model.rawAnalysis?.segments.filter({model.conversation.speakerID($0)==speakerID}).max(by:{($0.end-$0.start)<($1.end-$1.start)}) {model.playExcerpt(start:segment.start,end:min(segment.end,segment.start+12),segment:segment.id)}
                } label:{Label(VL.text("Послушать"),systemImage:"play.fill")}.buttonStyle(QuietButton()).disabled(model.selection?.audioURL==nil)
            }
            HStack(spacing:10) {
                Button(VL.text("Существующий человек")) {chooser.route = .existingPerson;error=nil}.buttonStyle(QuietButton(primary:chooser.route == .existingPerson))
                Button {chooser.registerNewPerson();error=nil} label:{Label(VL.text("Новый человек"),systemImage:"person.badge.plus")}.buttonStyle(QuietButton(primary:chooser.route == .newPerson)).accessibilityLabel(VL.text("Зарегистрировать нового собеседника"))
            }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if chooser.route == .existingPerson {
                        TextField(VL.text("Поиск по имени"),text:$chooser.search).textFieldStyle(.roundedBorder).accessibilityLabel(VL.text("Поиск существующего собеседника"))
                        ForEach(people) {person in
                            Button {chooser.select(person.id,in:model.voiceLibrary);error=nil} label: {
                                HStack(spacing:12) {
                                    Image(systemName:"person.crop.circle").font(.system(size:24)).foregroundColor(Ink.secondary)
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(person.name).font(.system(size:14,weight:.medium))
                                        Text(person.samples.isEmpty ? VL.text("Голос пока не сохранён"):VL.text("Подтверждённых образцов: \(person.samples.count)")).font(.system(size:11)).foregroundColor(Ink.secondary)
                                    }
                                    Spacer()
                                    Image(systemName:chooser.selectedProfileID==person.id ? "checkmark.circle.fill":"circle").foregroundColor(Ink.secondary)
                                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(chooser.selectedProfileID==person.id ? Ink.selection:Ink.surface).cornerRadius(8).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(VL.text("Выбрать ")+person.name).accessibilityAddTraits(chooser.selectedProfileID==person.id ? .isSelected:[])
                        }
                        if people.isEmpty {
                            Text(model.voiceLibrary.activeProfiles.isEmpty ? VL.text("Сохранённых собеседников пока нет."):VL.text("Других людей с таким именем не найдено.")).font(.system(size:13)).foregroundColor(Ink.secondary)
                            Button(VL.text("Зарегистрировать нового человека")) {chooser.registerNewPerson()}.buttonStyle(QuietButton())
                        }
                        if let person=selectedPerson {
                            Divider()
                            Text(VL.text("Выбран: ")+person.name).font(.system(size:13,weight:.medium))
                            Text(sample == nil ? VL.text("Отдельного образца голоса нет. Подтвердится только имя в этой записи."):sampleAlreadySaved ? VL.text("Этот образец уже сохранён. Повторное подтверждение не добавит дубликат."):VL.text("Подтверждение имени сохранит образец этого голоса для будущего сравнения.")).font(.system(size:11)).foregroundColor(Ink.secondary)
                            Menu(VL.text("Управление голосом…")) {
                                Button(VL.text("Удалить сохранённый голос…"),role:.destructive) {chooser.requestVoiceDeletion(person.id,in:model.voiceLibrary)}
                            }.menuStyle(.borderlessButton).fixedSize().font(.system(size:12))
                        }
                    } else {
                        Text(VL.text("Зарегистрировать нового человека")).font(.system(size:15,weight:.medium))
                        TextField(VL.text("Имя нового собеседника"),text:$chooser.name).textFieldStyle(.roundedBorder).accessibilityLabel(VL.text("Имя нового собеседника"))
                        Toggle(VL.text("Сохранить голос для будущих записей"),isOn:$chooser.remember).toggleStyle(.checkbox).disabled(sample==nil)
                        Text(sample == nil ? VL.text("Отдельного образца нет. Можно сохранить только имя."):VL.text("Голос сохранится только после вашего подтверждения. Предложенные имена сами по себе ничего не обучают.")).font(.system(size:11)).foregroundColor(Ink.secondary)
                        Text(VL.text("Новый человек не будет связан с ранее выбранным профилем.")).font(.system(size:11)).foregroundColor(Ink.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text(VL.text("Имя обновится в репликах, текстовом и визуальном саммари. Аудио, исходная речь и прежние результаты сохранятся.")).font(.system(size:11)).foregroundColor(Ink.secondary)
            if let error {Text(error).font(.system(size:12)).foregroundColor(Ink.text).accessibilityLabel(VL.text("Ошибка: ")+error)}
            Divider()
            HStack {
                Spacer();Button(VL.text("Отмена")) {dismiss()}.buttonStyle(QuietButton())
                Button(chooser.route == .existingPerson ? VL.text("Подтвердить человека"):VL.text("Зарегистрировать")) {
                    guard let choice else{return}
                    if model.assignSpeaker(speakerID,name:choice.name,profile:choice.profileID,remember:choice.remember) {dismiss()} else {error=model.analysisMessage ?? VL.text("Не удалось сохранить собеседника.")}
                }.buttonStyle(QuietButton(primary:true)).keyboardShortcut(.defaultAction).disabled(choice==nil)
            }
        }.padding(24).frame(width:500,height:590).background(Ink.canvas)
        .onAppear {
            if let rejectedProfileID {chooser.rejectedProfileIDs.insert(model.voiceLibrary.canonical(rejectedProfileID))}
            else if let id=model.conversation.identities[speakerID]?.profileID {chooser.select(id,in:model.voiceLibrary)}
            if model.voiceLibrary.activeProfiles.isEmpty {chooser.registerNewPerson()}
        }
        .confirmationDialog(VL.text("Удалить сохранённый голос?"),isPresented:Binding(get:{chooser.pendingVoiceDeletion != nil},set:{if !$0 {chooser.cancelVoiceDeletion()}}),presenting:deletionPerson) {person in
            Button(VL.text("Удалить голос"),role:.destructive) {
                if let id=chooser.confirmedVoiceDeletion(in:model.voiceLibrary),!model.forgetVoice(id) {error=model.analysisMessage}
            }
            Button(VL.text("Отмена"),role:.cancel) {chooser.cancelVoiceDeletion()}
        } message: {person in
            Text(VL.text("Будут удалены только образцы голоса «")+person.name+VL.text("» и будущие подсказки. Записи, исходная речь, назначенные исторические имена и результаты анализа сохранятся. Это не удаление записей."))
        }
    }
}

struct NativeVoiceProfileSheet:View {
    @ObservedObject var model:NativeMacModel
    let profileID:UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var deleting=false
    @State private var removingSamples=false
    @State private var failure:String?
    private var profile:AIVoiceProfile? {model.voiceLibrary.activeProfiles.first {$0.id==profileID}}
    private func title(_ sample:AIVoiceSample)->String {
        if let id=sample.recordingID,let item=model.library?.items.first(where:{$0.audioURL?.deletingPathExtension().lastPathComponent==id}) {return item.title}
        return sample.recordingTitle ?? VL.text("Ранее сохранённая запись")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text(VL.text("Собеседник")).font(.system(size:23,weight:.semibold));Spacer();Button(VL.text("Закрыть")) {dismiss()}.keyboardShortcut(.cancelAction).buttonStyle(.plain)}
            if let profile {
                TextField(VL.text("Имя"),text:$name).textFieldStyle(.roundedBorder)
                Text(VL.text("Имя обновится в записях, привязанных к этому человеку. Индивидуальные имена и исходные цитаты сохранятся.")).font(.system(size:11)).foregroundColor(Ink.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        Text(VL.text("Подтверждённые образцы · \(profile.samples.count)")).font(.system(size:14,weight:.medium))
                        ForEach(Array(profile.samples.enumerated()),id:\.offset) {index,sample in
                            VStack(alignment:.leading,spacing:8) {
                                Text(title(sample)).font(.system(size:13,weight:.medium)).lineLimit(2)
                                Text(sample.confirmedAt.vectaFormatted(date:.abbreviated,time:.shortened)+(sample.speechSeconds.map {" · "+String(format:VL.text("%.0f с речи"),$0)} ?? "")).font(.system(size:11)).foregroundColor(Ink.secondary)
                                HStack {
                                    if let recording=sample.recordingID {
                                        Button(VL.text("Открыть запись")) {dismiss();model.openVoiceRecording(recording)}.buttonStyle(.plain)
                                        if let start=sample.start,let end=sample.end {Button(VL.text("Послушать")) {dismiss();model.openVoiceRecording(recording,start:start,end:min(end,start+12))}.buttonStyle(.plain)}
                                    }
                                    Spacer()
                                    Menu {Button(VL.text("Это другой человек · отделить образец")) {model.separateVoiceSample(profileID,index:index)}} label:{Image(systemName:"ellipsis")}.help(VL.text("Исправить ошибочный образец"))
                                }.font(.system(size:12))
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Ink.surface).cornerRadius(8)
                        }
                        if profile.samples.isEmpty {Text(VL.text("Голос не сохранён. Добавьте образец из расшифровки записи.")).font(.system(size:12)).foregroundColor(Ink.secondary)}
                    }
                }
                HStack {
                    Menu(VL.text("Другие действия")) {
                        Menu(VL.text("Объединить с")) {ForEach(model.voiceLibrary.activeProfiles.filter {$0.id != profileID}) {target in Button(target.name) {model.updateVoices {try $0.merge(profileID,into:target.id)};dismiss()}}}
                        Button(VL.text("Удалить собеседника…"),role:.destructive) {deleting=true}
                    }.menuStyle(.borderlessButton)
                    Spacer();Button(VL.text("Сохранить имя")) {
                        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
                        guard !clean.isEmpty,clean.count<=120,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {failure=VL.text("Введите имя длиной до 120 символов.");return}
                        model.analysisMessage=nil
                        model.updateVoices {value in if let index=value.profiles.firstIndex(where:{$0.id==profileID}) {value.profiles[index].name=clean}}
                        if let message=model.analysisMessage {failure=message}else{dismiss()}
                    }.buttonStyle(QuietButton(primary:true)).keyboardShortcut(.defaultAction)
                }
                Button(role:.destructive) {removingSamples=true} label:{Label(VL.text("Забыть голос"),systemImage:"trash")}
                    .buttonStyle(QuietButton())
                if let failure {Text(failure).font(.system(size:12))}
            }
        }.padding(24).frame(width:440,height:480).background(Ink.canvas)
        .onAppear {name=profile?.name ?? ""}
        .confirmationDialog(VL.text("Удалить собеседника?"),isPresented:$deleting) {
            Button(VL.text("Удалить собеседника"),role:.destructive) {model.analysisMessage=nil;model.updateVoices {try $0.retire(profileID)};if let message=model.analysisMessage {failure=message}else{dismiss()}}
            Button(VL.text("Отмена"),role:.cancel) {}
        } message:{Text(VL.text("Сохранённый голос будет удалён. Аудио, расшифровки и назначенные в записях имена останутся."))}
        .confirmationDialog(VL.text("Удалить сохранённый голос?"),isPresented:$removingSamples) {
            Button(VL.text("Удалить голос"),role:.destructive) {if model.forgetVoice(profileID) {dismiss()} else {failure=model.analysisMessage}}
            Button(VL.text("Отмена"),role:.cancel) {}
        } message:{Text(VL.text("Собеседник исчезнет из списка сохранённых голосов и подсказок. Имена в прежних записях, аудио и расшифровки сохранятся."))}
    }
}
