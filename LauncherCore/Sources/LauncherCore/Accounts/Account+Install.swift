import Foundation

extension Account {
    /// Downloads the version of `product` Microsoft serves now and extracts it into the product's
    /// staging folder, for `InstallationStore.addStagedGame(of:consented:)`. The account must own
    /// the product. Cancelling stops the service and keeps the download for the next install.
    /// - Returns: the version extracted.
    public func install(
        _ product: GameProduct, with setup: ServiceSetup,
        progress: AsyncStream<InstallProgress>.Continuation
    ) async throws -> String {
        defer { progress.finish() }
        let store = InstallationStore(in: setup.directory)
        let staging = store.staging(for: product)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try await withService(setup, for: "install") { channel in
            try await channel.install(
                storeID: product.storeID, market: WinePrefix.market, staging: staging
            ) { progress.yield($0) }
        }
    }

    /// Asks for every product's package in one start of the service.
    public func servedPackages(
        of products: [GameProduct], with setup: ServiceSetup
    ) async throws -> [GameProduct: Result<GamePackage, ServiceFailure>] {
        try await withService(setup, for: "check") { channel in
            var packages: [GameProduct: Result<GamePackage, ServiceFailure>] = [:]
            for product in products {
                do {
                    packages[product] = .success(
                        try await channel.package(
                            storeID: product.storeID, market: WinePrefix.market))
                } catch let failure as ServiceFailure {
                    packages[product] = .failure(failure)
                }
            }
            return packages
        }
    }
}
