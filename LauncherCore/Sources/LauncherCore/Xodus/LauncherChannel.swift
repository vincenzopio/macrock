import Foundation
import SwiftProtobuf
import Synchronization
import System

/// The launcher's end of an account service's launcher channel: a socket whose other end is the
/// service's standard input, so that only the launcher can ask the service about its account.
/// The service answers one request at a time and its replies carry no ID, so requests wait for
/// each other, and a request that does not finish closes the channel. Closing the channel stops
/// the service.
final class LauncherChannel: Sendable {
    /// The version of the channel's messages this launcher speaks.
    static let protocolVersion: UInt32 = 2

    private let socket: FileDescriptor
    private let requestLock = Mutex(())

    /// A connected pair: the channel, and the end the service takes as its standard input.
    static func pair() throws -> (channel: LauncherChannel, serviceEnd: FileHandle) {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw Errno(rawValue: errno) }
        let channel = LauncherChannel(socket: FileDescriptor(rawValue: ends[0]))
        let serviceEnd = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout.size(ofValue: on))
        // Without SO_NOSIGPIPE, writing to a service that has exited would kill the launcher.
        guard setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &on, size) == 0,
            fcntl(ends[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(ends[1], F_SETFD, FD_CLOEXEC) == 0
        else { throw Errno(rawValue: errno) }
        return (channel, serviceEnd)
    }

    private init(socket: FileDescriptor) {
        self.socket = socket
    }

    deinit {
        try? socket.close()
    }

    /// The version of the channel's messages the service speaks.
    func hello() async throws -> UInt32 {
        var hello = Xodus_Hello()
        hello.protocol = Self.protocolVersion
        return try await call(.launcherHello, hello, answer: Xodus_Hello.self).protocol
    }

    /// Signs the account in with what Microsoft's sign-in page posted. The service registers the
    /// device first if it is not registered yet.
    /// - Parameter inlineAuth: whether the page is the one an earlier `.inlineAuth` named.
    func signIn(_ serverData: ServerData, inlineAuth: Bool) async throws -> SignInOutcome {
        var request = Xodus_SignIn()
        request.serverData = serverData.json
        request.inlineAuth = inlineAuth
        switch try await call(.launcherSignIn, request, answer: Xodus_SignInResult.self).outcome {
        case .signedIn: return .signedIn
        case .inlineAuthURL(let address):
            guard let url = URL(string: address) else { throw XodusError.unexpectedReply }
            return .inlineAuth(url)
        case .failure(let failure): throw ServiceFailure(failure)
        case nil: throw XodusError.unexpectedReply
        }
    }

    /// Forgets the signed-in user and, with `device`, the device's registration too, which
    /// removes the account's Keychain item. What is already gone counts as forgotten.
    func signOut(device: Bool) async throws {
        var request = Xodus_SignOut()
        request.device = device
        switch try await call(.launcherSignOut, request, answer: Xodus_SignOutResult.self).outcome {
        case .signedOut: return
        case .failure(let failure): throw ServiceFailure(failure)
        case nil: throw XodusError.unexpectedReply
        }
    }

    /// What the service holds for the account. Reading it may wait for the user to answer a
    /// Keychain prompt.
    func accountStatus() async throws -> AccountStatus {
        let result = try await call(
            .launcherAccountStatus, Google_Protobuf_Empty(), answer: Xodus_AccountStatusResult.self)
        switch result.outcome {
        case .status(let status): return try AccountStatus(status)
        case .failure(let failure): throw ServiceFailure(failure)
        case nil: throw XodusError.unexpectedReply
        }
    }

    /// The signed-in user's gamertag, which the service asks Microsoft for.
    func gamertag() async throws -> String {
        let result = try await call(
            .launcherProfile, Google_Protobuf_Empty(), answer: Xodus_ProfileResult.self)
        switch result.outcome {
        case .profile(let profile): return profile.gamertag
        case .failure(let failure): throw ServiceFailure(failure)
        case nil: throw XodusError.unexpectedReply
        }
    }

    /// The package Microsoft serves now for the game, found without downloading it.
    func package(storeID: String, market: String) async throws -> GamePackage {
        var request = Xodus_Package()
        request.productID = storeID
        request.market = market
        switch try await call(.launcherPackage, request, answer: Xodus_PackageResult.self).outcome {
        case .package(let package): return GamePackage(package)
        case .failure(let failure): throw ServiceFailure(failure)
        case nil: throw XodusError.unexpectedReply
        }
    }

    /// Downloads the package Microsoft serves now into `staging`, a folder on the volume the game
    /// goes to, and extracts the game into `staging/game`. `progress` is called on the channel's
    /// thread. Cancelling closes the channel, which stops the service; the download stays in
    /// `staging` for the next install.
    /// - Returns: the installed game's version.
    func install(
        storeID: String, market: String, staging: URL,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws -> String {
        var request = Xodus_Install()
        request.productID = storeID
        request.market = market
        request.staging = staging.path(percentEncoded: false)
        let outcome = try await exchange(.launcherInstall, request) {
            payload -> Result<String, ServiceFailure>? in
            switch try Xodus_InstallUpdate(reply: payload).update {
            case .progress(let update):
                progress(try InstallProgress(update))
                return nil
            case .installed(let game): return .success(game.version)
            case .failure(let failure): return .failure(ServiceFailure(failure))
            case nil: throw XodusError.unexpectedReply
            }
        }
        return try outcome.get()
    }

    private func call<Answer: SwiftProtobuf.Message>(
        _ type: Xodus_XodusMessageType, _ request: some SwiftProtobuf.Message,
        answer: Answer.Type
    ) async throws -> Answer {
        let payload = try await exchange(type, request) { $0 }
        guard !payload.isEmpty else { throw XodusError.emptyReply }
        return try Answer(reply: payload)
    }

    /// Sends a request and reads its replies until `answer` takes one as the last, on a thread of
    /// its own: the service can take long, waiting for Microsoft or for the user to answer a
    /// Keychain prompt. A reply that `answer` cannot take closes the channel, since the replies
    /// after it would be read as those of the next request.
    private func exchange<Answer: Sendable>(
        _ type: Xodus_XodusMessageType, _ request: some SwiftProtobuf.Message,
        answer: @escaping @Sendable (Data) throws -> Answer?
    ) async throws -> Answer {
        let type = UInt16(type.rawValue)
        let frame = try XodusFrame(
            magic: .protobuf, type: type, payload: try request.serializedBytes()
        ).encoded()
        do {
            return try await withTaskCancellationHandler {
                try await runOnDedicatedThread {
                    try self.requestLock.withLock { _ in
                        do {
                            try self.socket.writeAll(frame)
                            while true {
                                let header = try XodusFrame.header(
                                    self.receive(XodusFrame.headerSize), magic: .protobuf)
                                guard header.type == type + 1 else {
                                    throw XodusError.unexpectedReply
                                }
                                if let answered = try answer(self.receive(header.length)) {
                                    return answered
                                }
                            }
                        } catch {
                            self.shutDown()
                            throw error is Errno ? XodusError.channelClosed : error
                        }
                    }
                }
            } onCancel: {
                shutDown()
            }
        } catch XodusError.channelClosed where Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Reads exactly `count` bytes.
    private func receive(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let read = try data.withUnsafeMutableBytes {
                try socket.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[received...]))
            }
            guard read > 0 else { throw XodusError.channelClosed }
            received += read
        }
        return data
    }

    /// Ends the channel both ways, keeping its descriptor, which a request may be using until it
    /// sees the end.
    private func shutDown() {
        Darwin.shutdown(socket.rawValue, SHUT_RDWR)
    }
}

enum SignInOutcome: Sendable, Equatable {
    case signedIn
    /// Microsoft wants the user on this page first; what it posts signs in again, as `inlineAuth`.
    case inlineAuth(URL)
}

/// What the account service holds for its account, read from the Keychain alone.
struct AccountStatus: Sendable, Equatable {
    let state: SignInState
    /// Microsoft refused the user's token for a request since the service started: the user must
    /// sign in again.
    let mustSignInAgain: Bool
}

extension AccountStatus {
    init(_ status: Xodus_AccountStatus) throws {
        switch status.state {
        case .empty: state = .empty
        case .deviceOnly: state = .deviceOnly
        case .signedIn: state = .signedIn
        case .unspecified, .UNRECOGNIZED: throw XodusError.unexpectedReply
        }
        mustSignInAgain = status.signInAgain
    }
}

/// The game's package as Microsoft serves it now.
public struct GamePackage: Sendable, Equatable {
    /// The game's version, such as 1.26.5203.0.
    public let version: String
    /// The size of the download, in bytes.
    public let size: Int64
}

extension GamePackage {
    init(_ package: Xodus_GamePackage) {
        version = package.version
        size = Int64(clamping: package.size)
    }

    public func isNewer(than installed: String) -> Bool {
        version.compare(installed, options: .numeric) == .orderedDescending
    }
}

public struct InstallProgress: Sendable, Equatable {
    public enum Phase: Sendable {
        /// What an earlier install downloaded counts as done.
        case downloading
        case extracting
    }

    public let phase: Phase
    /// The bytes of the phase done so far, out of `total`.
    public let done: Int64
    public let total: Int64
}

extension InstallProgress {
    init(_ progress: Xodus_InstallProgress) throws {
        switch progress.phase {
        case .downloading: phase = .downloading
        case .extracting: phase = .extracting
        case .unspecified, .UNRECOGNIZED: throw XodusError.unexpectedReply
        }
        done = Int64(clamping: progress.done)
        total = Int64(clamping: progress.total)
    }
}

/// Why the account service could not do what the launcher asked.
public enum ServiceFailure: Error, Equatable {
    /// What was sent to sign in is not what Microsoft's sign-in page posts.
    case invalidServerData
    /// Microsoft could not be reached, or gave an answer the service does not understand.
    case microsoftUnavailable
    /// Microsoft refused the sign-in or the user's token, with its status (an HRESULT) when it
    /// gave one: the user must sign in again.
    case refused(status: UInt32?)
    /// The Keychain refused the service the account's credentials.
    case keychainRefused
    case notSignedIn
    case notOwned
    /// The volume of the staging folder has too little room: the install needs `bytesNeeded`
    /// free on it.
    case noSpace(bytesNeeded: Int64)
    /// The package kept arriving damaged from Microsoft's servers.
    case packageDamaged
    /// The package is not one the service can extract, or not the content its license is for.
    case packageUnreadable
    /// Reading or writing the staging folder failed.
    case diskFailed
    /// A reason this launcher does not know.
    case unknown
}

extension ServiceFailure {
    init(_ failure: Xodus_Failure) {
        switch failure.reason {
        case .invalidServerData: self = .invalidServerData
        case .unavailable: self = .microsoftUnavailable
        case .refused: self = .refused(status: failure.status == 0 ? nil : failure.status)
        case .keychain: self = .keychainRefused
        case .notSignedIn: self = .notSignedIn
        case .notOwned: self = .notOwned
        case .noSpace: self = .noSpace(bytesNeeded: Int64(clamping: failure.bytesNeeded))
        case .damaged: self = .packageDamaged
        case .unreadablePackage: self = .packageUnreadable
        case .disk: self = .diskFailed
        case .unspecified, .UNRECOGNIZED: self = .unknown
        }
    }
}

extension SwiftProtobuf.Message {
    /// A reply's message: one that does not decode is not what the launcher asked for.
    fileprivate init(reply payload: Data) throws {
        do {
            try self.init(serializedBytes: payload)
        } catch {
            throw XodusError.unexpectedReply
        }
    }
}
