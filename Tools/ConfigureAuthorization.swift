import Foundation
import Darwin
@main struct ConfigureAuthorization {
    static func line(_ prompt: String, secret: Bool = false) throws -> String {
        guard isatty(STDIN_FILENO) == 1 else { throw VectaAuthorizationError.invalidCredentials }
        print(prompt, terminator: ": ");fflush(stdout)
        var original = termios()
        if secret {
            guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw VectaAuthorizationError.invalidCredentials }
            var hidden = original;hidden.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else { throw VectaAuthorizationError.invalidCredentials }
        }
        defer { if secret { var restored=original;_ = tcsetattr(STDIN_FILENO, TCSANOW, &restored);print() } }
        guard let value = readLine() else { throw VectaAuthorizationError.invalidCredentials }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func main() throws {
        let value = try VectaPartnerCredentials(clientID: line("PLAUD Partner client ID"), clientSecret: line("Client secret", secret: true),
                                               domain: line("Domain (platform-us.plaud.ai or platform-jp.plaud.ai)"), userID: line("PLAUD partner user ID"))
        try VectaCredentialStore.save(value)
        print("Saved to your login Keychain. No credentials were written to this repository.")
    }
}
