import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { PRIVACY_UPDATED, SUPPORT_EMAIL } from '@/lib/site'

export const metadata = pageMetadata('/legal/privacy/')

// What the app and the site collect or send, by category. Keep feature details (plugins, keys,
// setting names) out: they change with releases, and this page doesn't need them (#583).
export default function PrivacyPage() {
  const email = <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>
  return (
    <PageShell title="Privacy Policy" showUpdated updated={PRIVACY_UPDATED}>
      <p>
        This policy explains how SERP (“we”) handles information in the Keybumps macOS app and on
        keybumps.app.
      </p>

      <h2>Information on your Mac</h2>
      <p>
        Content you create or keep in Keybumps, such as copied items, screenshots, recordings,
        transcripts, and translations, is stored and processed on your Mac, along with your settings
        and history. We don’t receive it, and the app doesn’t send it anywhere. Some features use
        services built into macOS, which Apple provides under its own privacy policy.
      </p>

      <h2>When the app goes online</h2>
      <p>The app has no advertising or usage analytics. It goes online for these reasons:</p>
      <ul>
        <li>
          <strong>Updates.</strong> Keybumps checks updates.keybumps.app for new versions. That
          request includes your IP address and app version, as any web request does.
        </li>
        <li>
          <strong>Downloads.</strong> Some features download files they need the first time you use
          them, such as a speech recognition model from Hugging Face, which receives a standard web
          request.
        </li>
        <li>
          <strong>License activation.</strong> When you activate, check, or deactivate your license,
          the app sends your license key and a one-way hash of your Mac’s hardware identifier (the
          identifier itself never leaves your Mac) to Polar, which issues and manages Keybumps
          license keys. This enforces the license’s Mac limit and lets refunded licenses be revoked.
        </li>
        <li>
          <strong>Crash and problem reports</strong>, described next.
        </li>
      </ul>

      <h2>Crash and problem reports</h2>
      <p>
        When Keybumps crashes or freezes, it sends a crash report to Sentry, a service that collects
        crash reports for us, so we can find and fix the cause. Crash reports are on by default, and
        you can turn them off in Keybumps’ settings.
      </p>
      <p>
        When you report a problem from the app, it sends what you write to Sentry, with your email
        address if you add one for a reply. It sends a problem report even when crash reports are
        off, because you chose to send it.
      </p>
      <p>A report includes:</p>
      <ul>
        <li>for a crash or freeze, where in Keybumps’ code it happened;</li>
        <li>the Keybumps and macOS versions, and which Keybumps plugins are on;</li>
        <li>
          technical details about your Mac and its state at the time, such as its model, processor
          type, and memory in use;
        </li>
        <li>
          a random identifier Keybumps creates for itself on your Mac, so we can tell how many Macs
          a problem affects;
        </li>
        <li>for a problem report, what you write, and which macOS permissions Keybumps has.</li>
      </ul>
      <p>
        Keybumps never adds the content you keep in it, your searches, or window or document titles
        to a report. Before a report leaves your Mac, it removes the file paths, file names, links,
        and email addresses it finds in error messages. In a problem report, it removes file paths,
        links, and email addresses from what you write and otherwise sends it, so leave out anything
        you’d rather not share.
      </p>
      <p>
        If you add your email to a problem report, we can see it alongside other reports from the
        same copy of Keybumps. Sentry receives your IP address with each report, as with any web
        request, but we’ve set it not to store the address or the location it suggests. Sentry
        stores reports in the United States and handles them on our behalf.
      </p>

      <h2>Purchases</h2>
      <p>
        Checkout is handled by Polar, our merchant of record. Polar collects your name, email,
        billing address, and payment details under its own privacy policy, and emails your license
        key with your receipt. We can see your email address, order details, license key, and
        country in Polar to provide support and handle refunds. We never see your full card number.
      </p>
      <p>
        When you buy, our website tells Google Analytics about the purchase, and about a full refund
        of it, so we can see which pages lead to purchases: the order number, product, amount, tax,
        currency, and any discount code. It also adds the anonymous IDs Google Analytics gave your
        browser, which travel to Polar with your checkout to make the link. If you declined
        analytics, or you’re in the EU, the EEA, the UK, or Switzerland and didn’t allow them, it
        sends nothing about your purchase. It never sends your name, email, address, or payment
        details.
      </p>
      <p>
        If a partner’s or another tracked link brought you to our website, it also tells Dub, which
        runs our partner program, about the purchase and any renewal or refund of it, so the partner
        is credited and paid: the order number, amount, and currency, the referral, which travels to
        Polar with your checkout, and Polar’s customer number. If you declined cookies, or you’re in
        the EU, the EEA, the UK, or Switzerland and didn’t allow them, no partner is credited. Dub
        never receives your name, email, or payment details.
      </p>

      <h2>Website</h2>
      <p>
        keybumps.app is hosted on Cloudflare, which processes standard request logs (such as IP
        address and browser) to deliver and protect the site.
      </p>
      <p>
        To understand how many people visit, which pages they use, and which ads bring them here,
        the live keybumps.app site loads analytics and advertising tools through Google Tag Manager,
        such as Google Analytics and Meta’s pixel. These tools receive standard request details,
        such as your IP address, browser, the page you visit, and the page that linked you there,
        and they may set cookies. Each handles that data under its own privacy policy. Analytics run
        only on the live website: never in the Keybumps app, and never on test or staging versions
        of the site.
      </p>
      <p>
        If you’re in the EU, the EEA, the UK, or Switzerland, the site asks before these tools set
        cookies, and you can accept or decline. To change your choice, clear keybumps.app’s site
        data in your browser, and the site asks again. Elsewhere, they run by default, and you can
        block or delete their cookies in your browser.
      </p>
      <p>
        If you arrive through a partner’s or another tracked link, Dub’s script, also loaded through
        Google Tag Manager, keeps the referral, and any partner discount it comes with, in cookies
        for up to 90 days, so the partner is credited if you buy.
      </p>

      <h2>Email</h2>
      <p>
        If you email us, or add your email to a problem report, we keep the conversation to help
        you. Polar sends your receipt and license key. We don’t sell your email address or share it
        beyond the services named on this page.
      </p>

      <h2>Retention and your rights</h2>
      <p>
        We keep purchase and license records for as long as your license is active and as required
        for tax and accounting, and crash and problem reports only as long as we need them to fix
        problems. You can ask us to access, correct, or delete the information we hold about you by
        emailing {email}. Data stored on your Mac is under your control and is removed when you
        delete it or uninstall Keybumps and its folders.
      </p>

      <h2>Children</h2>
      <p>Keybumps is not directed at children under 13.</p>

      <h2>Changes</h2>
      <p>We’ll post any changes here with a new date. Questions go to {email}.</p>
    </PageShell>
  )
}
