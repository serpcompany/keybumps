import { describe, expect, it } from "vitest";
import { generateLicenseKey, normalizeLicenseKey } from "../src/keys";

describe("License Keys", () => {
  it("uses the product prefix and four Crockford groups", () => {
    expect(generateLicenseKey("KB")).toMatch(/^KB(-[0-9A-HJKMNP-TV-Z]{4}){4}$/);
  });

  it("normalizes case, spaces, and look-alike characters after the prefix", () => {
    expect(normalizeLicenseKey(" kb-abcd-ilo1-2345-6789 ", "KB")).toBe("KB-ABCD-1101-2345-6789");
  });

  it("adds a missing prefix", () => {
    expect(normalizeLicenseKey("ABCD-EFGH-JKMN-PQRS", "KB")).toBe("KB-ABCD-EFGH-JKMN-PQRS");
  });
});
