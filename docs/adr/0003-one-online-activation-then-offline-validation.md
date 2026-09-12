---
status: accepted
---

# ADR 0005: Activate once, then validate offline

Each one-time SuperMac purchase permits one Mac activation. The app makes one narrow online activation request to a standard licensing or commerce service, binds the license to that Mac using a provider-supported device fingerprint, stores signed activation proof locally, and validates that proof offline on later launches. Periodic license checks, user accounts, subscriptions, and transmission of searches, clipboard content, dictated text, histories, or usage data are excluded.

License activation is the first onboarding step and precedes capability and permission setup. Detailed disclosure of the device-bound license model belongs on the purchase website rather than in a dedicated in-app disclosure screen.

License transfer, self-service deactivation, and multi-device allowances are deferred rather than approximated in the MVP. The exact provider, fingerprint construction, local secure-storage mechanism, recovery policy, and reinstall behavior remain implementation decisions that must be resolved before licensing is built.
