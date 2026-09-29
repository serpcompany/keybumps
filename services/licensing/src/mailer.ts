// License Key email delivery. Never log recipients, keys, or message bodies.

export interface KeyEmail {
  productName: string;
  key: string;
}

export interface KeyMailer {
  sendKeys(to: string, keys: KeyEmail[]): Promise<void>;
}

/**
 * Sends through Cloudflare Email Service's `send_email` binding. `send` rejects on failure.
 * The sender is also where replies go, so there is no separate reply-to.
 */
export class CloudflareMailer implements KeyMailer {
  constructor(
    private readonly binding: SendEmail,
    private readonly from: EmailAddress,
  ) {}

  async sendKeys(to: string, keys: KeyEmail[]): Promise<void> {
    await this.binding.send({ from: this.from, to, ...keyEmailContent(keys) });
  }
}

/** Parses `Name <address>` (or a bare address) from the EMAIL_FROM var. */
export function parseSender(value: string): EmailAddress {
  const match = value.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  return match ? { name: match[1], email: match[2] } : { name: "", email: value.trim() };
}

export function keyEmailContent(keys: KeyEmail[]): { subject: string; text: string; html: string } {
  const product = keys[0]?.productName ?? "Keybumps";
  const plural = keys.length > 1;
  const subject = plural ? `Your ${product} license keys` : `Your ${product} license key`;
  const lines = keys.map((entry) => `${entry.productName}: ${entry.key}`);
  const text = [
    `Thanks for buying ${product}.`,
    "",
    plural ? "Your license keys:" : "Your license key:",
    ...lines,
    "",
    `Download ${product}: https://keybumps.app/download`,
    `To activate, open ${product}, go to Settings > License, and paste your key.`,
    "",
    "Lost this email? Request it again at https://keybumps.app/license.",
  ].join("\n");
  const html = [
    `<p>Thanks for buying ${escapeHtml(product)}.</p>`,
    `<p>${plural ? "Your license keys:" : "Your license key:"}</p>`,
    ...keys.map((entry) => `<p><strong>${escapeHtml(entry.productName)}</strong><br><code style="font-size:18px">${escapeHtml(entry.key)}</code></p>`),
    `<p><a href="https://keybumps.app/download">Download ${escapeHtml(product)}</a>. To activate, open ${escapeHtml(product)}, go to Settings &gt; License, and paste your key.</p>`,
    `<p>Lost this email? Request it again at <a href="https://keybumps.app/license">keybumps.app/license</a>.</p>`,
  ].join("\n");
  return { subject, text, html };
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Keys that fail this many sends are left to support and the resend form. */
const MAX_EMAIL_ATTEMPTS = 5;

/**
 * Sends this customer's active keys that haven't been emailed. The keys are claimed atomically
 * first (`key_emailed_at` set by one UPDATE ... RETURNING), so overlapping webhook deliveries and
 * cron runs never send the same key twice. A failed send releases the claim and counts an attempt.
 * A crash between claiming and sending leaves the key unsent; the customer can use the resend form.
 */
export async function deliverPendingKeys(db: D1Database, mailer: KeyMailer, customerId: string, now: number): Promise<void> {
  const { results: claimed } = await db
    .prepare(
      `UPDATE licenses SET key_emailed_at = ?
       WHERE customer_id = ? AND status = 'active' AND key_emailed_at IS NULL AND email_attempts < ?
       RETURNING id, license_key AS key, product_id`,
    )
    .bind(now, customerId, MAX_EMAIL_ATTEMPTS)
    .all<{ id: string; key: string; product_id: string }>();
  if (claimed.length === 0) return;
  try {
    const customer = await db.prepare("SELECT email FROM customers WHERE id = ?").bind(customerId).first<{ email: string }>();
    const { results: products } = await db.prepare("SELECT id, name FROM products").all<{ id: string; name: string }>();
    const name = new Map(products.map((product) => [product.id, product.name]));
    if (!customer) throw new Error("customer missing");
    await mailer.sendKeys(customer.email, claimed.map((row) => ({ productName: name.get(row.product_id) ?? row.product_id, key: row.key })));
  } catch (error) {
    await db.batch(
      claimed.map((row) =>
        db.prepare("UPDATE licenses SET key_emailed_at = NULL, email_attempts = email_attempts + 1 WHERE id = ?").bind(row.id),
      ),
    );
    throw error;
  }
}

/** Keys still unsent a week after purchase are left to support. */
const RETRY_WINDOW = 7 * 86_400;

/** Emails keys whose purchase-time send failed. Run on a schedule; the fewest-attempted go first. */
export async function deliverUnsentKeys(db: D1Database, mailer: KeyMailer, now: number): Promise<void> {
  const { results } = await db
    .prepare(
      `SELECT customer_id FROM licenses
       WHERE key_emailed_at IS NULL AND status = 'active' AND customer_id IS NOT NULL
         AND created_at > ? AND email_attempts < ?
       GROUP BY customer_id ORDER BY MIN(email_attempts), MIN(created_at) LIMIT 50`,
    )
    .bind(now - RETRY_WINDOW, MAX_EMAIL_ATTEMPTS)
    .all<{ customer_id: string }>();
  for (const { customer_id } of results) {
    try {
      await deliverPendingKeys(db, mailer, customer_id, now);
    } catch {
      // Counted as an attempt; tried again on a later run.
    }
  }
}
