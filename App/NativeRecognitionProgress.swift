import SwiftUI

struct NativeRecognitionProgress: View {
    let progress: AIRecognitionProgress
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(VL.text("Распознавание · готово \(progress.completedChunks) из \(progress.totalChunks)"))
                Spacer(minLength:8)
                if let current = progress.currentChunk { Text(VL.text("Фрагмент \(current)")) }
            }.font(.system(size:11)).foregroundColor(Ink.secondary)
            ProgressView(value:progress.processedSeconds,total:progress.totalSeconds).tint(Ink.accent)
                .accessibilityLabel(VL.text("Завершённые фрагменты распознавания"))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct NativeAIQueueControl: View {
    @ObservedObject var host: LocalAIHost
    var body: some View {
        Button(host.queuePaused ? VL.text("Продолжить очередь") : VL.text("Пауза очереди")) { host.setQueuePaused(!host.queuePaused) }
            .buttonStyle(QuietButton())
    }
}
