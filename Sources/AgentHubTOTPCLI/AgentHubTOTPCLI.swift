import AgentHubTOTPKit
import Foundation

@main
struct AgentHubTOTPCLI {
    static func main() {
        do {
            let vault = TOTPVault()
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw CLIError.usage }
            switch command {
            case "list":
                for entry in vault.entries {
                    print("\(entry.id)\t\(entry.issuer)\t\(entry.account)")
                }
            case "get":
                guard arguments.count == 2, let entry = vault.metadata(for: arguments[1]) else { throw TOTPError.entryNotFound }
                // The vault performs LocalAuthentication before reading the Keychain item.
                print(try vault.code(for: entry.id))
            case "get-by-label":
                guard arguments.count == 3,
                      let entry = vault.metadata(issuer: arguments[1], account: arguments[2]) else { throw TOTPError.entryNotFound }
                print(try vault.code(for: entry.id))
            case "help", "--help", "-h":
                print("用法：agenthub-totp list | agenthub-totp get <entry-id> | agenthub-totp get-by-label <issuer> <account>")
            default:
                throw CLIError.usage
            }
        } catch {
            fputs("agenthub-totp: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
}

private enum CLIError: LocalizedError {
    case usage
    var errorDescription: String? { "用法：agenthub-totp list | agenthub-totp get <entry-id> | agenthub-totp get-by-label <issuer> <account>" }
}
