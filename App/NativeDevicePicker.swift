import SwiftUI
import NotePinTransport

struct DevicePickerView: View {
    @ObservedObject var model: NativeMacModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(VL.text("Подключить Plaud")).font(.title2.weight(.semibold)); Spacer(); Button(model.scanning ? VL.text("Поиск идёт…"):VL.text("Искать снова"), action: model.scan).disabled(model.scanning) }
            Text(VL.text("Оставьте включённый Plaud рядом с Mac. Закройте подключённое к нему приложение на другом устройстве. Выберите свой диктофон из списка."))
                .font(.caption).foregroundColor(.secondary)
            Text(model.pickerStatus).font(.caption).foregroundColor(.secondary)
            if model.candidates.isEmpty {
                if model.scanning { ProgressView(VL.text("Ищем Plaud рядом…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Text(VL.text("Совместимые устройства не найдены. Поиск можно повторить.")).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                List(model.candidates) { candidate in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.displayName).font(.headline)
                            Text(VL.text("Серийный номер: \(candidate.maskedSerial) · RSSI \(candidate.rssi)")).font(.caption).foregroundColor(.secondary)
                            if candidate.model == nil { Text(VL.text("Модель не подтверждена")).font(.caption).foregroundColor(.orange) }
                            else if candidate.advertisement?.protocolVersion == nil { Text(VL.text("Версия протокола не подтверждена — подключение недоступно")).font(.caption).foregroundColor(.secondary) }
                        }
                        Spacer()
                        Button(VL.text("Подключить")) { model.choose(candidate) }.disabled(!candidate.canConnect)
                    }.padding(.vertical, 5)
                }
            }
            HStack { Spacer(); Button(VL.text("Закрыть"), action: model.closePicker) }
        }.padding(22)
    }
}

