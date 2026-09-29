// Provider-neutral events (docs/adr/0001-licensing.md §3). Adapters translate a provider's
// webhooks into these; fulfillment never sees provider payloads.

export interface NormalizedOrder {
  ref: string;
  customer: { ref: string; email: string };
  /** The provider's product id, used to find the Offer when no `offer` metadata is present. */
  productRef: string;
  /** Explicit Offer id from checkout metadata, for pricing variants. */
  offerId: string | null;
  /** Anything but `purchase` and `subscription_create` extends an existing subscription License. */
  billingReason: "purchase" | "subscription_create" | "subscription_cycle" | "other";
  subscription: { ref: string; currentPeriodEnd: number | null } | null;
}

export type NormalizedEvent =
  | { type: "order.paid"; order: NormalizedOrder }
  /** `renewal` is true for subscription renewals and plan changes, which never mint a License. */
  | { type: "order.refunded"; orderRef: string; renewal: boolean }
  /** The subscription is paid through `currentPeriodEnd` (active, renewed, uncanceled, or canceled at period end). */
  | { type: "subscription.period"; subscriptionRef: string; currentPeriodEnd: number }
  /** The subscription has ended and its License must be revoked. */
  | { type: "subscription.ended"; subscriptionRef: string }
  | { type: "ignored" };

export interface VerifiedWebhook {
  /** The provider's delivery id, used for idempotency. */
  eventId: string;
  event: NormalizedEvent;
}

export interface ProviderAdapter {
  readonly name: string;
  /** Returns null when the signature, timestamp, or payload is invalid. */
  verifyWebhook(request: Request): Promise<VerifiedWebhook | null>;
}
