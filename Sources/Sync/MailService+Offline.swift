import Foundation

/// What an account edit is about to replace, so a probe that finishes after the user cancelled can be
/// undone instead of silently keeping the edit.
struct AccountRestorePoint {
    let account: Account
    let password: String?
}

/// Account changes that must not depend on reaching the server (C-18).
@MainActor
extension MailService {
    /// Saves edited settings and the password locally and reconnects in the background.
    /// Unlike updateCredentials() this never contacts IMAP or SMTP, so a wrong server name, a wrong port or
    /// an offline Mac can still be saved ("save without verifying") and fixed later.
    /// An empty password keeps the saved one.
    func saveCredentialsWithoutVerifying(_ account: Account, password: String?) throws {
        guard self.account(account.id) != nil else { throw NetError.server("The account no longer exists.") }
        if let password, !password.isEmpty { try Keychain.set(password, for: account.id) }
        updateAccount(account)
        // Reconnect with the new settings now; a failure is recorded as the account's last error, not lost.
        engines[account.id]?.resetConnections()
    }

    /// The settings and password an edit is about to replace (nil if the account is gone).
    func restorePoint(for accountID: String) -> AccountRestorePoint? {
        guard let a = account(accountID) else { return nil }
        return AccountRestorePoint(account: a, password: Keychain.get(accountID))
    }

    /// Puts back settings and password captured by restorePoint(), for an edit the user cancelled while
    /// its check was still running. Does nothing if the account was removed in the meantime.
    func restore(_ point: AccountRestorePoint) {
        guard account(point.account.id) != nil else { return }
        updateAccount(point.account)
        if let password = point.password { try? Keychain.set(password, for: point.account.id) }
        engines[point.account.id]?.resetConnections()
    }
}
