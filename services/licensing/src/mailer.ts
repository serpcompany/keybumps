// License Key email delivery. Never log recipients, keys, or message bodies.

export interface KeyEmail {
  productName: string;
  key: string;
}

export interface KeyMailer {
  sendKeys(to: string, keys: KeyEmail[]): Promise<void>;
}

/** Sends through Cloudflare Email Service's `send_email` binding. `send` rejects on failure. */
export class CloudflareMailer implements KeyMailer {
  constructor(
    private readonly binding: SendEmail,
    private readonly from: EmailAddress,
    private readonly replyTo: string,
  ) {}

  async sendKeys(to: string, keys: KeyEmail[]): Promise<void> {
    await this.binding.send({ from: this.from, to, replyTo: this.replyTo, ...keyEmailContent(keys) });
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

/** Sends any of this customer's active keys not emailed yet, then marks them sent. */
export async function deliverPendingKeys(db: D1Database, mailer: KeyMailer, customerId: string, now: number): Promise<void> {
  const { results } = await db
    .prepare(
      `SELECT l.id, l.license_key AS key, p.name AS productName, c.email
       FROM licenses l JOIN products p ON p.id = l.product_id JOIN customers c ON c.id = l.customer_id
       WHERE l.customer_id = ? AND l.status = 'active' AND l.key_emailed_at IS NULL`,
    )
    .bind(customerId)
    .all<{ id: string; key: string; productName: string; email: string }>();
  if (results.length === 0) return;
  await mailer.sendKeys(results[0].email, results.map(({ productName, key }) => ({ productName, key })));
  await db.batch(results.map((row) => db.prepare("UPDATE licenses SET key_emailed_at = ? WHERE id = ?").bind(now, row.id)));
}

/** Keys still unsent a week after purchase are left to support. */
const RETRY_WINDOW = 7 * 86_400;

/** Emails keys whose purchase-time send failed. Run on a schedule. */
export async function deliverUnsentKeys(db: D1Database, mailer: KeyMailer, now: number): Promise<void> {
  const { results } = await db
    .prepare(
      `SELECT DISTINCT customer_id FROM licenses
       WHERE key_emailed_at IS NULL AND status = 'active' AND customer_id IS NOT NULL AND created_at > ?
       LIMIT 50`,
    )
    .bind(now - RETRY_WINDOW)
    .all<{ customer_id: string }>();
  for (const { customer_id } of results) {
    try {
      await deliverPendingKeys(db, mailer, customer_id, now);
    } catch {
      // Try again on the next run.
    }
  }
}
