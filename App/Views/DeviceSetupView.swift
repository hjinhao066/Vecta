import AppKit
import SwiftUI

struct DeviceSetupView: View {
    @ObservedObject var model: NativeMacModel
    @State private var step = 0
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var userID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    @State private var domain = "platform-us.plaud.ai"
    @State private var error: String?
    @State private var tutorialStep = 0
    @State private var completedTutorialSteps: Set<Int> = []
    @State private var showingSecretRecovery = false
    private let portal = URL(string: "https://platform.plaud.ai/developer/portal")!

    init(model: NativeMacModel) {
        self.model = model
        #if VECTA_DEVELOPMENT
        if CommandLine.arguments.contains("--verify-device-portal") { _step = State(initialValue: 1) }
        if CommandLine.arguments.contains("--verify-device-portal-step4") {
            _step = State(initialValue: 1)
            _tutorialStep = State(initialValue: 3)
            _completedTutorialSteps = State(initialValue: [0, 1, 2])
        }
        if CommandLine.arguments.contains("--verify-device-portal-recovery") {
            _step = State(initialValue: 1)
            _showingSecretRecovery = State(initialValue: true)
        }
        if CommandLine.arguments.contains("--verify-device-credentials") { _step = State(initialValue: 2) }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            setupProgress
            ScrollView(.vertical) {
                setupContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 4)
            }
            footer
        }.padding(28).frame(width: 920, height: 640).background(Ink.canvas).foregroundColor(Ink.text)
    }

    private var header: some View {
        HStack {
            Label(VL.text("Настроим ваш PLAUD"), systemImage: "externaldrive.badge.checkmark")
                .font(.title2.weight(.semibold))
            Spacer()
            Button(VL.text("Закрыть")) { model.showingDeviceSetup = false }.buttonStyle(QuietButton())
        }
    }

    private var setupProgress: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { index in
                Label([VL.text("Как это работает"), VL.text("Доступ PLAUD"), VL.text("Ввод данных и подключение")][index],
                      systemImage: index < step ? "checkmark.circle.fill" : "\(index + 1).circle")
                    .foregroundColor(index == step ? Ink.text : Ink.muted)
                if index < 2 { Image(systemName: "chevron.right").foregroundColor(Ink.muted) }
            }
        }.font(.system(size: 12))
    }

    @ViewBuilder private var setupContent: some View {
        if step == 0 {
            introduction
        } else if step == 1 {
            portalGuide
        } else {
            credentialsForm
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 42)).foregroundColor(Ink.success)
            Text(VL.text("Один раз настроить. Дальше — напрямую к Mac.")).font(.system(size: 26, weight: .semibold))
            Text(VL.text("При первой настройке Vecta получает у PLAUD авторизацию именно для вашего диктофона. Нужны интернет и ваш Partner-доступ. Мы проведём вас через портал и подключение по Bluetooth."))
            Label(VL.text("Перед подключением включите режим сопряжения на PLAUD"), systemImage: "antenna.radiowaves.left.and.right")
            Text(VL.text("Ваш диктофон должен быть отвязан от других устройств. Если он уже привязан, сначала отвяжите его в приложении, через которое подключали. Vecta не выполняет сброс или удаление записей автоматически."))
                .font(.system(size: 13)).foregroundColor(Ink.secondary)
            Label(VL.text("Записи не отправляются для авторизации"), systemImage: "waveform")
            Label(VL.text("Долгосрочные ключи защищены Связкой ключей macOS"), systemImage: "key.fill")
            Label(VL.text("Последующие подключения используют сохранённую авторизацию"), systemImage: "wifi.slash")
            Text(VL.text("После сброса, смены привязки или некоторых обновлений устройства может потребоваться повторная настройка. Офлайн-подключение проверяется отдельно для модели и прошивки."))
                .font(.caption).foregroundColor(Ink.secondary)
        }.lineSpacing(4).padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Ink.surface).cornerRadius(12)
    }

    private var portalGuide: some View {
        HStack(alignment: .top, spacing: 24) {
            tutorialSidebar.frame(width: 255)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(showingSecretRecovery ? VL.text("Данные существующего приложения") : VL.text("Доступ к PLAUD — по шагам"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button { NSWorkspace.shared.open(portal) } label: {
                        Label(VL.text("Открыть портал"), systemImage: "arrow.up.right.square")
                    }.buttonStyle(QuietButton())
                }
                PlaudAccessTutorial(selection: tutorialStep, isRecovery: showingSecretRecovery)
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var tutorialSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(VL.text("СОЗДАТЬ НОВОЕ ПРИЛОЖЕНИЕ")).font(.system(size: 11, weight: .semibold)).foregroundColor(Ink.secondary)
            Text(VL.text("Четыре шага в браузере, затем ввод данных в Vecta.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            VStack(spacing: 4) {
                ForEach(0..<PlaudAccessTutorial.steps.count, id: \.self) { index in
                    tutorialButton(index)
                }
            }
            Divider()
            existingAppBranch
            Divider()
            savedCredentialsShortcut
        }
    }

    private var existingAppBranch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(VL.text("НЕОБЯЗАТЕЛЬНО · ВМЕСТО СОЗДАНИЯ")).font(.system(size: 10, weight: .semibold)).foregroundColor(Ink.secondary)
            Button { showingSecretRecovery = true } label: {
                Label(VL.text("У меня уже есть приложение"), systemImage: "key")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(QuietButton())
                .accessibilityAddTraits(showingSecretRecovery ? [.isSelected] : [])
            Text(VL.text("Найти Client ID или восстановить секрет без создания нового приложения."))
                .font(.system(size: 11)).foregroundColor(Ink.secondary)
        }
    }

    private var savedCredentialsShortcut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(VL.text("Client ID и Secret Key уже сохранены?")).font(.system(size: 12, weight: .medium))
            Button(VL.text("Пропустить инструкцию — ввести данные")) { showCredentials() }.buttonStyle(QuietButton())
            Text(VL.text("Нужны оба значения, не ключ из API Keys.")).font(.system(size: 11)).foregroundColor(Ink.secondary)
        }
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(VL.text("Введите Client ID и Secret Key")).font(.title3.weight(.semibold))
            Text(VL.text("Скопируйте оба значения из своего SDK-приложения в портале PLAUD. Vecta сама получит временный API-токен, подпись серийного номера и клиентские ключи. После успешного подключения на вашем Mac сохранится только долгосрочная авторизация устройства; введённые здесь credentials не сохраняются."))
                .font(.system(size: 13)).foregroundColor(Ink.secondary)
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).accessibilityLabel("PLAUD Partner Client ID")
            SecureField("Secret Key (Client Secret)", text: $clientSecret).textFieldStyle(.roundedBorder).accessibilityLabel("PLAUD Partner Client Secret")
            Picker(VL.text("Регион Partner API"), selection: $domain) {
                Text("US · platform-us.plaud.ai").tag("platform-us.plaud.ai")
                Text("JP · platform-jp.plaud.ai").tag("platform-jp.plaud.ai")
            }
            DisclosureGroup(VL.text("Идентификатор пользователя Partner API")) {
                TextField("User ID", text: $userID).textFieldStyle(.roundedBorder)
                Text(VL.text("Для нового подключения идентификатор создан локально. Если продолжаете прежнюю привязку, используйте её прежний User ID. Это не адрес почты и не пароль PLAUD."))
                    .font(.caption).foregroundColor(Ink.secondary)
            }
            Button(VL.text("Использовать ранее настроенный Partner-доступ")) {
                do { try model.useSavedDeviceAccess() } catch { self.error = error.localizedDescription }
            }.buttonStyle(QuietButton())
            Text(VL.text("Затем включите режим сопряжения на диктофоне и выберите его из списка. Сброс и удаление записей не нужны."))
                .font(.caption).foregroundColor(Ink.secondary)
            if let error { Text(error).foregroundColor(Ink.error).accessibilityLabel(VL.text("Ошибка: ") + error) }
        }.frame(maxWidth: 590, alignment: .topLeading)
    }

    @ViewBuilder private var footer: some View {
        if step == 1 {
            tutorialNavigation
        } else {
            HStack {
                if step == 2 {
                    Button(VL.text("Назад к инструкции")) { step = 1; error = nil }.buttonStyle(QuietButton())
                }
                Spacer()
                Button(step == 2 ? VL.text("Найти мой PLAUD") : VL.text("Начать настройку")) {
                    if step == 0 { step = 1 }
                    else { configureDeviceAccess() }
                }.buttonStyle(QuietButton(primary: true))
                    .disabled(step == 2 && (clientID.isEmpty || clientSecret.isEmpty || userID.isEmpty))
            }
        }
    }

    private var tutorialNavigation: some View {
        HStack(spacing: 10) {
            Button(VL.text("К началу настройки")) { step = 0; error = nil }.buttonStyle(QuietButton())
            Spacer(minLength: 8)
            if showingSecretRecovery {
                Button(VL.text("Вернуться к созданию приложения")) { showingSecretRecovery = false }.buttonStyle(QuietButton())
                Button(VL.text("Ввести Client ID и Secret Key")) { showCredentials() }.buttonStyle(QuietButton(primary: true))
            } else {
                Button(VL.text("Предыдущий шаг")) { tutorialStep -= 1 }.buttonStyle(QuietButton()).disabled(tutorialStep == 0)
                Button(tutorialNextTitle) { advanceTutorial() }.buttonStyle(QuietButton(primary: true))
            }
        }
    }

    private var tutorialNextTitle: String {
        switch tutorialStep {
        case 0: return VL.text("Далее: создать приложение")
        case 1: return VL.text("Далее: заполнить данные")
        case 2: return VL.text("Далее: скопировать ключи")
        default: return VL.text("Данные скопированы — ввести в Vecta")
        }
    }

    private func advanceTutorial() {
        completedTutorialSteps.insert(tutorialStep)
        if tutorialStep < PlaudAccessTutorial.steps.count - 1 { tutorialStep += 1 }
        else { showCredentials() }
    }

    private func showCredentials() {
        error = nil
        step = 2
    }

    private func configureDeviceAccess() {
        do {
            try model.configureDeviceAccess(VectaPartnerCredentials(
                clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                domain: domain,
                userID: userID.trimmingCharacters(in: .whitespacesAndNewlines)))
            clientSecret = ""
        } catch { self.error = error.localizedDescription }
    }

    private func tutorialButton(_ index: Int) -> some View {
        let selected = !showingSecretRecovery && tutorialStep == index
        let completed = completedTutorialSteps.contains(index)
        let title = PlaudAccessTutorial.steps[index].title
        let status = selected ? VL.text("Текущий") : (completed ? VL.text("Пройден") : VL.text("Впереди"))
        return Button { tutorialStep = index; showingSecretRecovery = false } label: {
            HStack(alignment: .center, spacing: 10) {
                tutorialMarker(index, selected: selected, completed: completed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(status).font(.system(size: 10)).foregroundColor(Ink.secondary)
                }
                Spacer(minLength: 0)
            }.multilineTextAlignment(.leading).padding(8).background(selected ? Ink.selection : .clear).cornerRadius(8)
        }.buttonStyle(.plain).accessibilityLabel(VL.text("Шаг \(index + 1) из 4: \(title). \(status)"))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func tutorialMarker(_ index: Int, selected: Bool, completed: Bool) -> some View {
        Group {
            if completed && !selected { Image(systemName: "checkmark") }
            else { Text(String(index + 1)) }
        }.font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            .background(selected ? Ink.accent : Ink.elevated)
            .foregroundColor(selected ? Ink.onAccent : (completed ? Ink.success : Ink.secondary)).clipShape(Circle())
    }
}

/// Illustrations, not screenshots or interactive vendor forms. Labels were checked in the public portal assets.
private struct PlaudAccessTutorial: View {
    struct Step {
        let title: String
        let instruction: String
        let heading: String
        let target: String
        let detail: String
    }
    static let steps = [
        Step(title: VL.text("Войти в портал"), instruction: VL.text("Откройте официальный портал PLAUD и войдите в свой аккаунт. Если сайт предлагает первоначальную настройку организации, завершите её в браузере. Затем перейдите к следующему шагу здесь, в Vecta."), heading: "PLAUD Platform", target: "portal.plaud.ai", detail: VL.text("Вход выполняется в браузере. Vecta не получает ваш пароль.")),
        Step(title: VL.text("Создать SDK-приложение"), instruction: VL.text("В переключателе приложений выберите Create App. Если предложен тип интеграции, выберите Embedded SDK — это Partner-доступ, нужный Vecta, а не OAuth. Нажмите Next на сайте, затем продолжите инструкцию в Vecta."), heading: "Choose app type", target: "Embedded SDK", detail: "Create App → Embedded SDK → Next"),
        Step(title: VL.text("Заполнить данные приложения"), instruction: VL.text("Укажите App Name, например Vecta Personal, и описание локального подключения своего диктофона. Заполните обязательные поля формы и загрузите логотип, если он требуется. Нажмите Create app на сайте, затем перейдите к копированию ключей."), heading: "Create a new app", target: "Create app", detail: "App Name · Brief Description / Description · Use Case"),
        Step(title: VL.text("Скопировать Client ID и Secret Key"), instruction: VL.text("После создания скопируйте Client ID и Secret Key с экрана credentials. Secret Key показывается только один раз: сохраните его в менеджере паролей. Когда оба значения сохранены, нажмите «Данные скопированы — ввести в Vecta» внизу."), heading: "Your credentials are shown below", target: "Client ID + Secret Key", detail: VL.text("На сайте: I have securely saved my Secret Key → Continue"))
    ]
    static let recovery = Step(title: VL.text("У меня уже есть приложение"), instruction: VL.text("Выберите своё SDK-приложение. Откройте App Settings → App Credentials и скопируйте Client ID. Если исходный секрет не сохранён, в Client Secrets нажмите Generate New Secret и сразу сохраните новый в менеджере паролей. Не удаляйте приложение и старые ключи."), heading: "App Settings", target: "Generate New Secret", detail: VL.text("App Credentials → Client Secrets; не API Keys"))

    let selection: Int
    let isRecovery: Bool
    private var current: Step { isRecovery ? Self.recovery : Self.steps[selection] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRecovery ? VL.text("НЕОБЯЗАТЕЛЬНЫЙ ПУТЬ · ПРИЛОЖЕНИЕ УЖЕ СОЗДАНО") : VL.text("ШАГ \(selection + 1) ИЗ \(Self.steps.count)"))
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Ink.secondary)
            Text(current.instruction).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            illustration
            if isRecovery {
                Text(VL.text("Сохраните оба значения и перейдите к их вводу. Если хотите создать новое приложение, вернитесь к инструкции кнопкой внизу."))
                    .font(.system(size: 12)).foregroundColor(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(VL.text("Это иллюстрация, не скриншот и не форма входа. Названия элементов сверены с публичным интерфейсом PLAUD; язык и расположение могут отличаться. Если Embedded SDK недоступен, требуется Partner-доступ PLAUD."))
                .font(.system(size: 10)).foregroundColor(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var illustration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<3) { _ in Circle().fill(Ink.border).frame(width: 7, height: 7) }
                Spacer()
                Text(VL.text("PLAUD Platform · схема шага")).font(.system(size: 10)).foregroundColor(Ink.secondary)
            }
            Divider()
            Text(current.heading).font(.system(size: 17, weight: .semibold))
            illustrationFields
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.circle.fill").font(.system(size: 22)).foregroundColor(Ink.success)
                Text(current.target).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.selection).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ink.success, lineWidth: 2))
            }.accessibilityElement(children: .combine).accessibilityLabel(VL.text("Нужный элемент на сайте: ") + current.target)
            Text(current.detail).font(.system(size: 11)).foregroundColor(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).background(Ink.surface).cornerRadius(12)
    }

    @ViewBuilder private var illustrationFields: some View {
        if isRecovery {
            HStack {
                Text("App Credentials").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("API Keys").font(.system(size: 12)).foregroundColor(Ink.muted)
            }
            exampleField("Client ID", VL.text("скопируйте значение с сайта"))
            Text("Client Secrets").font(.system(size: 13, weight: .medium))
        } else if selection == 2 {
            exampleField("App Name", "Vecta Personal")
            exampleField("Description", "Local macOS connection to my PLAUD")
        } else if selection == 3 {
            exampleField("Client ID", VL.text("скопируйте значение с сайта"))
            exampleField("Secret Key", "••••••••••••••••")
        } else if selection == 1 {
            Label("Create App", systemImage: "plus").font(.system(size: 12)).foregroundColor(Ink.secondary)
        }
    }

    private func exampleField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(Ink.secondary)
            Text(value).font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.elevated).cornerRadius(6)
        }
    }
}
