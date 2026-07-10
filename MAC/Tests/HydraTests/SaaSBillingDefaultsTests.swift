import Testing
@testable import Hydra

@Suite("SaaS billing defaults")
struct SaaSBillingDefaultsTests {
    @Test("migrates legacy saved providers to Lemon Squeezy")
    func migratesLegacyProviders() {
        let providers = SaaSBillingDefaults.providers(from: [
            "pay": "Moyasar (KSA)",
            "subProvider": "Tap Payments (KSA)"
        ])

        #expect(providers.payment == "Lemon Squeezy")
        #expect(providers.subscription == "Lemon Squeezy")
    }

    @Test("preserves explicit providers after defaults migration")
    func preservesVersionedProviders() {
        let providers = SaaSBillingDefaults.providers(from: [
            "billingDefaultsVersion": SaaSBillingDefaults.version,
            "pay": "Stripe",
            "subProvider": "Stripe"
        ])

        #expect(providers.payment == "Stripe")
        #expect(providers.subscription == "Stripe")
    }
}
