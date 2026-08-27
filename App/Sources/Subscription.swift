// Subscription.swift
//
// Stash Pro: €2.99 a month, auto-renewing, one product and no tiers.
//
// Until 1.0 the App Store price was the whole business model and this file did not need to
// exist — you paid €5 at the door and the app had no idea money was involved. 1.1 is free to
// download, so the door moved inside.
//
// What this owns: reading StoreKit's answer, buying, restoring, and forwarding the signed
// blobs to the box. What it deliberately does NOT own: deciding anything. `isEntitled` here
// is only ever a mirror of what the server said, because the server is what actually refuses
// to spend Bedrock and Groq money. A jailbroken device can make this class say whatever it
// likes and still get 402s all the way down.
//
// ponytail: no product cache, no offline receipt parsing, no local expiry arithmetic —
// StoreKit 2 already keeps `currentEntitlements` correct across devices and relaunches, and
// re-asking it costs nothing.

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class Subscription {
    static let shared = Subscription()

    static let productID = "dev.dmitryschab.Stash.pro.monthly"

    /// The product, once StoreKit hands it over. Nil means the App Store has not answered yet
    /// — or the product is misconfigured, which is why the paywall says so rather than
    /// rendering a buy button that cannot work.
    private(set) var product: Product?
    private(set) var isWorking = false
    private(set) var loadFailed = false

    /// Nil until the first sync completes. The paywall waits on it rather than guessing:
    /// flashing a checkout at somebody who already pays is the one failure worth a spinner.
    private(set) var hasSynced = false

    private var updates: Task<Void, Never>?

    private init() {}

    /// The price as the App Store would print it, in the viewer's own storefront currency.
    /// Never hardcode "€2.99" into the UI — Apple rejects a paywall whose price disagrees with
    /// the one they are about to charge, and every storefront disagrees.
    var displayPrice: String {
        #if DEBUG
        // `-showPaywall` runs with no App Store account and no StoreKit configuration (simctl
        // cannot load one), so `product` never arrives and the screen would advertise a
        // failure instead of a price. This is the price the product carries in App Store
        // Connect; it exists so the paywall can be screenshotted for App Review.
        if CommandLine.arguments.contains("-showPaywall"), product == nil { return "€2.99" }
        #endif
        return product?.displayPrice ?? ""
    }

    // MARK: Lifecycle

    /// Start listening and settle the entitlement. Called once, from the app's root.
    func start() {
        guard updates == nil else { return }
        // Transactions can arrive with no purchase in progress: a renewal, an Ask-to-Buy
        // approval, a refund, or the same Apple ID buying on another device. Each one has to
        // reach the server, so this listener outlives any individual purchase call.
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                if let transaction = try? update.payloadValue {
                    await transaction.finish()
                }
                await self.sync()
            }
        }
        Task { await load(); await sync() }
    }

    /// Fetch the product so the paywall can print a real price.
    func load() async {
        #if DEBUG
        // The screenshot path has no App Store account, and asking StoreKit for a product
        // raises a sign-in sheet over the very screen being captured. `displayPrice` already
        // supplies the price on this path.
        if CommandLine.arguments.contains("-showPaywall") { return }
        #endif
        do {
            product = try await Product.products(for: [Self.productID]).first
            loadFailed = product == nil
        } catch {
            loadFailed = true
            NSLog("Subscription: product load failed: %@", String(describing: error))
        }
    }

    /// Ask StoreKit what this Apple ID owns, tell the box, and adopt its answer.
    func sync() async {
        await StashSession.shared.syncEntitlement(
            signedTransaction: await currentSubscriptionJWS(),
            signedAppTransaction: await appTransactionJWS())
        hasSynced = true
    }

    // MARK: Buying

    /// Returns nil on success, or a sentence to put on screen. Cancelling is not an error and
    /// returns nil too — the user closed a sheet, they do not need to be told.
    func purchase() async -> String? {
        guard let product else { return "The subscription is not available right now." }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                // Unverified means StoreKit could not vouch for the signature. Do not finish
                // it and do not celebrate — the server would refuse it anyway.
                guard let transaction = try? verification.payloadValue else {
                    return "Apple could not verify that purchase."
                }
                await transaction.finish()
                await sync()
                return StashSession.shared.isEntitled
                    ? nil : "The purchase went through but Stash could not confirm it. Try Restore."
            case .pending:
                // Ask to Buy, or a bank that wants a second word. The listener above picks it
                // up whenever it clears, including on a later launch.
                return "That purchase needs approval before it can finish."
            case .userCancelled:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Guideline 3.1.1: a restore path that does not require signing in again.
    func restore() async -> String? {
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
        } catch {
            // A cancelled password prompt lands here too, so this is a note, not a failure.
            NSLog("Subscription: AppStore.sync failed: %@", String(describing: error))
        }
        await sync()
        return StashSession.shared.isEntitled ? nil : "No active subscription found for this Apple ID."
    }

    // MARK: StoreKit reads

    /// The signed transaction for a live Stash Pro entitlement, if there is one.
    private func currentSubscriptionJWS() async -> String? {
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? entitlement.payloadValue,
                  transaction.productID == Self.productID else { continue }
            return entitlement.jwsRepresentation
        }
        return nil
    }

    /// The app's own purchase record. This is what tells the server that somebody bought
    /// Stash back when it cost €5, so they must never see a paywall. Cheap and harmless to
    /// send every time; the server decides what it means.
    private func appTransactionJWS() async -> String? {
        guard let result = try? await AppTransaction.shared else { return nil }
        return result.jwsRepresentation
    }
}
