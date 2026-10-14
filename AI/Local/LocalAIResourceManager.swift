import Foundation
import Darwin

/// One lease across Vecta host instances, with OS pressure/thermal gating.
/// No inference or synchronous audio work executes on the main actor.
@MainActor final class LocalAIResourceManager {
    private var source: DispatchSourceMemoryPressure?
    private var descriptor: Int32 = -1
    private(set) var pressure: DispatchSource.MemoryPressureEvent = .normal
    var onCritical: (() -> Void)?
    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical],queue:.main)
        self.source = source
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            Task { @MainActor in
                self?.pressure = event
                if event.contains(.critical) { self?.onCritical?() }
            }
        }
        source.resume()
    }
    /// Reclaimable pages are an estimate, interpreted together with pressure,
    /// compression and thermal state rather than treating free RAM as a verdict.
    var constrainedHeadroom: Bool {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to:&statistics) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count)
            }
        }
        guard status == KERN_SUCCESS else { return false }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(),&pageSize) == KERN_SUCCESS else { return false }
        let reclaimable = (UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.purgeable_count)) * UInt64(pageSize)
        let compressed = UInt64(statistics.compressor_page_count) * UInt64(pageSize)
        return reclaimable < 256 * 1024 * 1024 && compressed > ProcessInfo.processInfo.physicalMemory / 4
    }
    var waitingReason: String? {
        if pressure.contains(.critical) { return VL.text("Недостаточно ресурсов: критическое давление памяти. Готовые фрагменты сохранены.") }
        if pressure.contains(.warning) { return VL.text("Очередь ожидает снижения давления памяти.") }
        if constrainedHeadroom { return VL.text("Очередь ожидает освобождения памяти: низкий запас и высокая компрессия.") }
        if ProcessInfo.processInfo.thermalState == .critical { return VL.text("Очередь ожидает снижения температуры Mac.") }
        if ProcessInfo.processInfo.physicalMemory < 8 * 1024 * 1024 * 1024 { return VL.text("Недостаточно памяти для установленной локальной модели.") }
        return nil
    }
    func acquire() throws -> Bool {
        guard descriptor < 0, waitingReason == nil else { return false }
        let root = VectaLegacyPaths.sharedLeaseRoot
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = root.appendingPathComponent("heavy-ai.lock")
        let fd = open(file.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw AIProcessingError.busy }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }
    func release() {
        if descriptor >= 0 { flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1 }
    }
    func stop() { source?.cancel(); source = nil; release() }
    deinit { if descriptor >= 0 { close(descriptor) }; source?.cancel() }
}
