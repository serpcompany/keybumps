import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import worker, { mailerOverride } from "../src/index";
import { CloudflareMailer, keyEmailContent, parseSender, type KeyEmail } from "../src/mailer";
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

/** Calls the Worker directly so the test can wait for work scheduled after the response. */
async function resend(email: string) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request("https://licensing.test/v1/resend-key", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email }),
    }),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

const runSchedule = () => worker.scheduled(createScheduledController(), env);

describe("key email on purchase", () => {
  it("emails the new key once, even when the order is redelivered", async () => {
    const paid = order("mail@example.com");
    expect(await deliver(paid)).toBe(200);
    expect(await deliver(paid)).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe("mail@example.com");
    expect(sent[0].keys).toEqual([{ productName: "Keybumps", key: expect.stringMatching(/^KB-/) }]);
  });

  it("acknowledges the order when sending fails, and the scheduled retry sends the key once", async () => {
    const paid = order("retry@example.com");
    failNext = true;
    expect(await deliver(paid)).toBe(200);
    expect(sent).toHaveLength(0);
    await runSchedule();
    expect(sent.filter((mail) => mail.to === "retry@example.com")).toHaveLength(1);
    await runSchedule();
    expect(sent.filter((mail) => mail.to === "retry@example.com")).toHaveLength(1);
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

describe("CloudflareMailer", () => {
  it("sends one message from the sender with both bodies", async () => {
    const calls: unknown[] = [];
    const binding = { send: async (message: unknown) => (calls.push(message), { messageId: "m1" }) } as unknown as SendEmail;
    await new CloudflareMailer(binding, parseSender("Keybumps <support@keybumps.app>")).sendKeys("a@b.co", [
      { productName: "Keybumps", key: "KB-AAAA-BBBB-CCCC-DDDD" },
    ]);
    expect(calls).toEqual([
      expect.objectContaining({
        from: { name: "Keybumps", email: "support@keybumps.app" },
        to: "a@b.co",
        subject: "Your Keybumps license key",
        text: expect.stringContaining("KB-AAAA-BBBB-CCCC-DDDD"),
        html: expect.stringContaining("KB-AAAA-BBBB-CCCC-DDDD"),
      }),
    ]);
  });

  it("parses a bare sender address", () => {
    expect(parseSender("support@keybumps.app")).toEqual({ name: "", email: "support@keybumps.app" });
  });
});
