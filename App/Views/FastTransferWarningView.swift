import SwiftUI

struct NativeFastTransferWarningView: View {
    let onContinue: (Bool) -> Void
    let onCancel: () -> Void
    @State private var doNotShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(VL.text("Передача по Wi‑Fi"), systemImage: "wifi").font(.title2.weight(.semibold))
            Text(VL.text("Mac временно подключится к точке доступа вашего PLAUD. Интернет и приложения, которым нужна текущая сеть, могут перестать работать на время передачи."))
                .font(.system(size: 14)).lineSpacing(4)
            Text(VL.text("После передачи Vecta попробует вернуть прежнюю сеть. Если macOS не позволит подключиться автоматически, Vecta отключит точку PLAUD — обычную сеть можно будет выбрать в меню Wi‑Fi. Если вы сами переключите сеть, Vecta не станет её отключать."))
                .font(.system(size: 13)).foregroundColor(Ink.secondary).lineSpacing(4)
            Toggle(VL.text("Больше не показывать"), isOn: $doNotShowAgain)
                .accessibilityHint(VL.text("Скрывает только это предупреждение. Передача по Wi‑Fi всё равно начинается только по нажатию Fast transfer."))
            HStack {
                Button(VL.text("Отмена"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(VL.text("Начать Fast transfer")) { onContinue(doNotShowAgain) }
                    .buttonStyle(QuietButton(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540).background(Ink.canvas).foregroundColor(Ink.text)
    }
}
