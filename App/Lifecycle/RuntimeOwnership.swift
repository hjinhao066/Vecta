import Foundation
import Darwin

/// One application owns the local inference mailbox. A lock
/// is released by the OS on exit/crash; children must never inherit ownership.
final class RuntimeOwnership {
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("runtime.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw OwnershipError.unavailable }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd); throw OwnershipError.unavailable
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(fd)
            throw reason == EWOULDBLOCK ? OwnershipError.alreadyRunning : OwnershipError.unavailable
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    enum OwnershipError: LocalizedError {
        case alreadyRunning, unavailable
        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return VL.text("Другая копия Vecta уже работает. Используйте её или полностью закройте перед запуском этой копии. Записи и обработка не изменены.")
            case .unavailable:
                return VL.text("Не удалось получить доступ к локальным компонентам Vecta. Проверьте доступ к папке данных; существующие файлы не изменены.")
            }
        }
    }
}
