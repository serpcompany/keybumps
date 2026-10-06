import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { SUPPORT_EMAIL } from '@/lib/site'

export const metadata = pageMetadata('/legal/privacy/')

export default function PrivacyPage() {
  const email = <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>
  return (
    <PageShell title="Privacy Policy" showUpdated>
      <p>
        This policy explains how SERP (“we”) handles information in the Keybumps macOS app and on
        keybumps.app.
      </p>

      <h2>The short version</h2>
      <p>
        What you do in Keybumps stays on your Mac. The app has no advertising, no analytics, no
        account, and no cloud sync. We never receive your searches, clipboard contents, screenshots,
        recordings, or transcripts. If Keybumps crashes or freezes, it sends us a crash report
        without any of those, and you can turn crash reports off. If you report a problem, it sends
        what you write.
      </p>

      <h2>Information stored on your Mac</h2>
      <ul>
        <li>
          <strong>Clipboard History</strong> keeps your most recent copied text and images locally.
          You can delete items at any time.
        </li>
        <li>
          <strong>Screenshots</strong> are saved where macOS or Keybumps saves them, and edited
          copies are saved beside the original.
        </li>
        <li>
          <strong>Dictation</strong> records audio and transcribes it on your Mac. Recordings and
          transcripts are stored in ~/Documents/Keybumps/recordings, where you can open or delete
          them.
        </li>
        <li>
          <strong>Snippets</strong> are stored on your Mac; the text of a snippet you mark sensitive
          is kept in your Mac’s Keychain.
        </li>
        <li>
          <strong>Timers</strong>, with any names you give them, are stored on your Mac until you
          delete them.
        </li>
        <li>
          <strong>Emoji Picker</strong> keeps your recently used emoji on your Mac. Turning off
          Remember recently used emoji in its settings clears them.
        </li>
        <li>
          <strong>Quick Search, Window Manager, and Shortcut Coach</strong> work from information
          already on your Mac and keep their settings and history locally.
        </li>
      </ul>
      <p>
        Translation uses Apple’s on-device Translation framework, and spoken playback uses macOS
        voices. Apple handles that data under its own privacy practices.
      </p>

      <h2>When the app goes online</h2>
      <ul>
        <li>
          <strong>Updates.</strong> Keybumps checks updates.keybumps.app for new versions. That
          request includes your IP address and app version, as any web request does.
        </li>
        <li>
          <strong>Speech model download.</strong> The first time you use Dictation, the app
          downloads the Whisper speech model from Hugging Face, which receives a standard web
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
        crash reports for us, so we can find and fix the cause. Crash reports are on by default. To
        stop sending them, turn off <strong>Send crash reports</strong> in Keybumps Settings ›
        General.
      </p>
      <p>
        <strong>Report a Problem…</strong>, in the Help menu, the menu bar menu, and Settings ›
        General, sends what you write to Sentry, with your email address if you add one for a reply.
        Before you send, it shows you the main details it adds. It sends a problem report even when
        crash reports are off, because you chose to send it.
      </p>
      <p>A report includes:</p>
      <ul>
        <li>for a crash or freeze, where in Keybumps’ code it happened;</li>
        <li>the Keybumps and macOS versions, and which Keybumps plugins are on;</li>
        <li>
          technical details about your Mac and its state at the time, such as its model, processor
          type, memory in use, whether Low Power Mode is on, and when Keybumps was opened;
        </li>
        <li>
          a random identifier Keybumps creates for itself on your Mac, so we can tell how many Macs
          a problem affects;
        </li>
        <li>
          for a problem report, what you write, and which permissions Keybumps has, such as
          Accessibility.
        </li>
      </ul>
      <p>
        Keybumps never adds your clipboard contents, snippets, transcripts, recordings, screenshots,
        searches, or window or document titles to a report. It removes file paths, file names,
        links, and email addresses from error messages before a report leaves your Mac. In a problem
        report, it removes file paths, links, and email addresses from what you write and otherwise
        sends it, so leave out anything you’d rather not share.
      </p>
      <p>
        If you add your email to a problem report, we can see it alongside other reports from the
        same copy of Keybumps. Nothing is sent when nothing goes wrong: there’s no report when you
        open Keybumps, and none about how long you use it. Sentry receives your IP address with each
        report, as with any web request, but we’ve set it not to store the address or the location
        it suggests. Sentry stores reports in the United States and handles them on our behalf.
      </p>

      <h2>Purchases</h2>
      <p>
        Checkout is handled by Polar, our merchant of record. Polar collects your name, email,
        billing address, and payment details under its own privacy policy, and emails your license
        key with your receipt. We can see your email address, order details, license key, and
        country in Polar to provide support and handle refunds. We never see your full card number.
      </p>

      <h2>Website</h2>
      <p>
        keybumps.app is hosted on Cloudflare, which processes standard request logs (such as IP
        address and browser) to deliver and protect the site.
      </p>
      <p>
        To understand how many people visit and which pages they use, the live keybumps.app site
        loads Google Tag Manager, which loads the analytics tags we configure in it. Google Tag
        Manager and those tags receive standard request details, such as your IP address, browser,
        the page you visit, and the page that linked you there, and analytics tags may set cookies.
        Google handles that data under its own privacy policy. Analytics run only on the live
        website: never in the Keybumps app, and never on test or staging versions of the site.
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
