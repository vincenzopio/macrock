/// What an account's service holds for it, as its `ACCOUNT_STATUS` tells.
enum SignInState: Sendable, Equatable {
    case signedIn
    /// A registered device and no user: signing in was cut short.
    case deviceOnly
    case empty
}
