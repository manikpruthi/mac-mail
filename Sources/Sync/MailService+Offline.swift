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
        guard let saved = self.account(account.id) else { throw NetError.server("The account no longer exists.") }
        if let password, !password.isEmpty { try Keychain.set(password, for: account.id) }
        let connectionChanged = account.connectionDiffers(from: saved)
        updateAccount(account)
        // updateAccount() already reset the connections when the servers changed (W-16); otherwise
        // reconnect once here so the saved password is used. A failure is recorded as the last error.
        if !connectionChanged { engines[account.id]?.resetConnections() }
    }

    /// The settings and password an edit is about to replace (nil if the account is gone).
    func restorePoint(for accountID: String) -> AccountRestorePoint? {
        guard let a = account(accountID) else { return nil }
        return AccountRestorePoint(account: a, password: Keychain.get(accountID))
    }

    /// Puts back settings and password captured by restorePoint(), for an edit the user cancelled while
    /// its check was still running. Does nothing if the account was removed in the meantime.
    func restore(_ point: AccountRestorePoint) {
        guard let current = account(point.account.id) else { return }
        let connectionChanged = point.account.connectionDiffers(from: current)
        // Restore the password before the reconnect below, so it reads the old one, not the cancelled edit's.
        if let password = point.password { try? Keychain.set(password, for: point.account.id) }
        updateAccount(point.account)
        // updateAccount() already reset the connections when the servers changed (W-16); otherwise
        // reconnect once so the restored password is used.
        if !connectionChanged { engines[point.account.id]?.resetConnections() }
    }
}
