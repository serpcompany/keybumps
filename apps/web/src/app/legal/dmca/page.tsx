import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { site } from '@/lib/site'

export const metadata = pageMetadata('/legal/dmca/')

export default function DmcaPage() {
  const email = (
    <a href={`mailto:${site.supportEmail}`} className="underline underline-offset-4">
      {site.supportEmail}
    </a>
  )
  return (
    <PageShell title="DMCA Copyright Policy" showUpdated>
      <p>
        SERP respects the intellectual property rights of others and responds to properly reported
        claims of copyright infringement on keybumps.app under the Digital Millennium Copyright Act
        (“DMCA”).
      </p>

      <h2>Filing a notice</h2>
      <p>Send notices to {email}. Under 17 U.S.C. § 512(c)(3), a notice must include:</p>
      <ul>
        <li>a physical or electronic signature of the copyright owner or an authorized agent;</li>
        <li>identification of the copyrighted work claimed to be infringed;</li>
        <li>identification of the infringing material and its URL on keybumps.app;</li>
        <li>your contact information: address, telephone number, and email;</li>
        <li>
          a statement that you believe in good faith that the use is not authorized by the owner,
          its agent, or the law; and
        </li>
        <li>
          a statement, under penalty of perjury, that the notice is accurate and that you are the
          owner or authorized to act for the owner.
        </li>
      </ul>

      <h2>Counter-notification</h2>
      <p>
        If you believe material was removed by mistake or misidentification, send {email} a
        counter-notification that meets the requirements of 17 U.S.C. § 512(g)(3).
      </p>
    </PageShell>
  )
}
