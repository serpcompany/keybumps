import type { Metadata } from 'next';
import Link from 'next/link';
import { LegalPage } from '../../components/site-chrome';
import { SUPPORT_EMAIL } from '../../lib/site';

export const metadata: Metadata = {
  title: 'Terms of Service — Keybumps',
  description: 'The terms that apply to buying and using Keybumps.',
};

export default function TermsPage() {
  return (
    <LegalPage title="Terms of Service">
      <p>
        These terms apply to the Keybumps macOS app, its licenses, and
        keybumps.app (together, the “Service”), provided by SERP (“we”, “us”).
        By downloading, buying, or using the Service you agree to them. If you
        do not agree, do not use the Service.
      </p>

      <h2>1. The app</h2>
      <p>
        Keybumps is a macOS utility for search, clipboard history, screenshots,
        dictation, window management, and shortcut coaching. It requires a Mac
        with Apple silicon running a supported version of macOS. Some features
        need macOS permissions such as Accessibility, Screen Recording, or
        Microphone, which you can grant or revoke at any time.
      </p>

      <h2>2. Purchases</h2>
      <p>
        Licenses are sold through Polar (polar.sh), which acts as our merchant
        of record. Polar processes your payment, charges any applicable sales
        tax or VAT, and issues your receipt, and its own terms apply to the
        payment. Prices are shown at checkout.
      </p>

      <h2>3. License</h2>
      <p>
        When you buy Keybumps we grant you a personal, non-exclusive,
        non-transferable license to install and use it on the number of Macs
        stated at purchase (currently one). A one-time license does not expire.
        It includes all future updates to Keybumps.
      </p>
      <p>
        The app activates your license online and checks in occasionally to keep
        it current. You may deactivate a Mac and move the license to another
        one. Do not share, resell, or publish your license key.
      </p>

      <h2>4. Restrictions</h2>
      <p>You may not:</p>
      <ul>
        <li>
          copy, sell, rent, or redistribute the app except as these terms allow;
        </li>
        <li>
          reverse engineer, decompile, or bypass its licensing, except where the
          law expressly permits it;
        </li>
        <li>use the Service for anything unlawful.</li>
      </ul>

      <h2>5. Refunds</h2>
      <p>
        Purchases come with a 30-day money-back guarantee. See the{' '}
        <Link href="/refunds">Refund Policy</Link>. A refunded, charged-back, or
        disputed purchase revokes its license.
      </p>

      <h2>6. Beta software</h2>
      <p>
        Pre-release versions may contain bugs, change, or lose features. Keep
        backups of anything important.
      </p>

      <h2>7. Third-party components</h2>
      <p>
        Keybumps includes open-source components, such as Sparkle, WhisperKit,
        OpenAI Whisper models, Rectangle, and Shotnix, each under its own
        license. Those licenses govern those components. Apple frameworks and
        services the app uses are subject to Apple’s terms.
      </p>

      <h2>8. Ownership</h2>
      <p>
        The app, its design, and the Keybumps name and artwork belong to us. You
        own the content you create or copy with the app.
      </p>

      <h2>9. Disclaimer</h2>
      <p>
        THE SERVICE IS PROVIDED “AS IS” AND “AS AVAILABLE” WITHOUT WARRANTIES OF
        ANY KIND, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A
        PARTICULAR PURPOSE, AND NON-INFRINGEMENT. DICTATION TRANSCRIPTS AND
        TRANSLATIONS MAY BE INACCURATE.
      </p>

      <h2>10. Limitation of liability</h2>
      <p>
        TO THE EXTENT THE LAW ALLOWS, WE ARE NOT LIABLE FOR ANY INDIRECT,
        INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR FOR LOST
        DATA OR PROFITS, ARISING FROM YOUR USE OF THE SERVICE. OUR TOTAL
        LIABILITY IS LIMITED TO THE AMOUNT YOU PAID FOR KEYBUMPS IN THE 12
        MONTHS BEFORE THE CLAIM.
      </p>

      <h2>11. Changes and termination</h2>
      <p>
        We may change or discontinue the Service and may update these terms by
        posting a new version here with a new date. We may revoke a license used
        in breach of these terms. Nothing here limits rights you have under
        consumer law in your country.
      </p>

      <h2>12. Contact</h2>
      <p>
        Questions go to <a href={`mailto:${SUPPORT_EMAIL}`}>{SUPPORT_EMAIL}</a>.
        See also the <Link href="/privacy">Privacy Policy</Link>.
      </p>
    </LegalPage>
  );
}
