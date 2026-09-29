import { exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mailerOverride } from "../src/index";
import { keyEmailContent, type KeyEmail } from "../src/mailer";
import { deliver, order } from "./polar-fixtures";

interface Sent {
  to: string;
  keys: KeyEmail[];
}

let sent: Sent[] = [];
let failNext = false;

beforeEach(async () => {
  sent = [];
  failNext = false;
  mailerOverride.current = {
    async sendKeys(to, keys) {
      if (failNext) {
        failNext = false;
        throw new Error("provider down");
      }
      sent.push({ to, keys });
    },
  };
  await admin("/admin/offers", { id: "keybumps-launch-a", product: "keybumps", provider: "polar", providerRef: "prod_keybumps", kind: "perpetual" });
});

afterEach(() => {
  mailerOverride.current = null;
});

async function admin(path: string, body: unknown) {
  return exports.default.fetch(`https://licensing.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer test-admin-token" },
    body: JSON.stringify(body),
  });
}

const resend = (email: string) =>
  exports.default.fetch("https://licensing.test/v1/resend-key", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });

describe("key email on purchase", () => {
  it("emails the new key once, even when the order is redelivered", async () => {
    const paid = order("mail@example.com");
    expect(await deliver(paid)).toBe(200);
    expect(await deliver(paid)).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe("mail@example.com");
    expect(sent[0].keys).toEqual([{ productName: "Keybumps", key: expect.stringMatching(/^KB-/) }]);
  });

  it("asks Polar to retry when sending fails, then sends only the unsent key", async () => {
    const paid = order("retry@example.com");
    failNext = true;
    expect(await deliver(paid)).toBe(502);
    expect(sent).toHaveLength(0);
    expect(await deliver(paid)).toBe(200);
    expect(sent).toHaveLength(1);
    expect(await deliver(paid)).toBe(200);
    expect(sent).toHaveLength(1);
  });
});

describe("resend-key", () => {
  it("resends active keys to the purchase address, at most once per interval", async () => {
    await deliver(order("again@example.com"));
    sent = [];
    expect((await resend(" Again@Example.com ")).status).toBe(202);
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe("again@example.com");
    expect((await resend("again@example.com")).status).toBe(202);
    expect(sent).toHaveLength(1);
  });

  it("gives the same response for an address that never bought", async () => {
    const response = await resend("stranger@example.com");
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ ok: true });
    expect(sent).toHaveLength(0);
  });

  it("rejects malformed addresses", async () => {
    expect((await resend("not-an-email")).status).toBe(400);
  });
});

it("builds a plain and HTML email that includes every key", () => {
  const content = keyEmailContent([{ productName: "Keybumps", key: "KB-AAAA-BBBB-CCCC-DDDD" }]);
  expect(content.subject).toBe("Your Keybumps license key");
  expect(content.text).toContain("KB-AAAA-BBBB-CCCC-DDDD");
  expect(content.html).toContain("KB-AAAA-BBBB-CCCC-DDDD");
  expect(content.text).toContain("https://keybumps.app/license");
});
