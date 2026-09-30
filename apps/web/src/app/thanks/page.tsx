import type { Metadata } from 'next';
import Link from 'next/link';
import { LegalPage } from '../../components/site-chrome';

export const metadata: Metadata = {
  title: 'Thanks for buying Keybumps',
  robots: { index: false, follow: false },
  // The URL carries Polar's customer-session token; never send it on as a Referer.
  referrer: 'no-referrer',
};

// Polar appends checkout and customer-session parameters to this URL. The page never reads
// or echoes them.
export default function ThanksPage() {
  return (
    <LegalPage title="Thanks for buying Keybumps" showUpdated={false}>
      <p>
        Your license key is in the receipt email from Polar, sent to the address
        you used at checkout. It usually arrives within a minute.
      </p>
      <h2>Activate Keybumps</h2>
      <ol>
        <li>
          <Link href="/download">Download Keybumps</Link> if you haven’t
          already.
        </li>
        <li>Open Keybumps and go to Settings → License.</li>
        <li>Paste your license key and choose Activate.</li>
      </ol>
      <p>
        No email? Check your spam folder, or{' '}
        <Link href="/license">find your key in the customer portal</Link>.
      </p>
    </LegalPage>
  );
}
