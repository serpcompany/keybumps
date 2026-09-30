import { PageShell } from '@/components/page-shell'
import { pageMetadata } from '@/lib/metadata'
import { LEGAL_UPDATED } from '@/lib/site'

export const metadata = pageMetadata('/legal/dmca/')

// Text from the SERP standard DMCA template (serp/docs/engineering/websites/pages/dmca/
// template.md), with {{domain.tld}} set to keybumps.app. dmca@keybumps.app must forward to
// dmca@serp.co through Cloudflare Email Routing (see the template's README).
const dmcaEmail = 'dmca@keybumps.app'
const link = 'underline underline-offset-4'

export default function DmcaPage() {
  return (
    <PageShell title="DMCA Copyright Policy">
      <p className="fine">
        <strong>Effective Date:</strong> {LEGAL_UPDATED}
      </p>
      <p>
        keybumps.app ("we," "us," or "our") respects the intellectual property rights of others and
        expects users of our products and services to do the same. In accordance with the Digital
        Millennium Copyright Act of 1998 ("DMCA"), the text of which may be found on the U.S.
        Copyright Office website at{' '}
        <a href="https://www.copyright.gov/legislation/dmca.pdf" className={link}>
          https://www.copyright.gov/legislation/dmca.pdf
        </a>
        , we will respond expeditiously to claims of copyright infringement committed using our
        products and services that are properly reported to our Designated Copyright Agent
        identified below.
      </p>

      <h2>1. Designated Copyright Agent</h2>
      <p>
        If you are a copyright owner, or authorized to act on behalf of one, and you believe that
        material available through our products or services infringes your copyright, please submit
        a notification of claimed infringement to our Designated Agent:
      </p>
      <address className="not-italic">
        SERP
        <br />
        TSMC LLC
        <br />
        1095 Sugarview Drive STE 500
        <br />
        Sheridan, WY 82801
        <br />
        Phone: 3236288306
        <br />
        Email:{' '}
        <a href={`mailto:${dmcaEmail}`} className={link}>
          {dmcaEmail}
        </a>
      </address>

      <h2>2. Filing a Notice of Claimed Infringement</h2>
      <p>
        To be effective under the DMCA, your written notification (a "Notice") must include
        substantially all of the following (see 17 U.S.C. § 512(c)(3)):
      </p>
      <ol>
        <li>
          A physical or electronic signature of the copyright owner or a person authorized to act on
          their behalf.
        </li>
        <li>
          Identification of the copyrighted work claimed to have been infringed, or, if multiple
          works are covered by a single notification, a representative list of such works.
        </li>
        <li>
          Identification of the material that is claimed to be infringing or to be the subject of
          infringing activity and that is to be removed or access to which is to be disabled, and
          information reasonably sufficient to permit us to locate the material (for example, the
          URL(s) where it appears).
        </li>
        <li>
          Information reasonably sufficient to permit us to contact you, such as an address,
          telephone number, and, if available, an email address.
        </li>
        <li>
          A statement that you have a good-faith belief that use of the material in the manner
          complained of is not authorized by the copyright owner, its agent, or the law.
        </li>
        <li>
          A statement that the information in the notification is accurate, and{' '}
          <strong>under penalty of perjury</strong>, that you are the copyright owner or are
          authorized to act on behalf of the copyright owner.
        </li>
      </ol>
      <p>Please send completed Notices to the Designated Agent listed in Section 1.</p>
      <blockquote>
        <p>
          <strong>Note:</strong> Under Section 512(f) of the DMCA, any person who knowingly
          materially misrepresents that material or activity is infringing may be subject to
          liability for damages, including costs and attorneys' fees. Please do not make false
          claims.
        </p>
      </blockquote>

      <h2>3. Counter-Notification</h2>
      <p>
        If you believe that material you posted was removed or disabled by mistake or
        misidentification, you may submit a written counter-notification to our Designated Agent. To
        be effective, your counter-notification must include substantially all of the following (see
        17 U.S.C. § 512(g)(3)):
      </p>
      <ol>
        <li>Your physical or electronic signature.</li>
        <li>
          Identification of the material that has been removed or to which access has been disabled,
          and the location at which the material appeared before it was removed or disabled.
        </li>
        <li>
          A statement <strong>under penalty of perjury</strong> that you have a good-faith belief
          that the material was removed or disabled as a result of mistake or misidentification.
        </li>
        <li>
          Your name, address, and telephone number, and a statement that you consent to the
          jurisdiction of the Federal District Court for the judicial district in which your address
          is located (or, if your address is outside the United States, for any judicial district in
          which we may be found), and that you will accept service of process from the person who
          provided the original Notice or an agent of that person.
        </li>
      </ol>
      <p>
        Upon receipt of a valid counter-notification, we may forward it to the original complaining
        party. If that party does not notify us within ten (10) business days that they have filed
        an action seeking a court order to restrain the allegedly infringing activity, we may, in
        our discretion, restore the removed material.
      </p>

      <h2>4. Repeat Infringer Policy</h2>
      <p>
        In accordance with the DMCA and other applicable law, we have adopted a policy of
        terminating, in appropriate circumstances and at our sole discretion, the accounts of users
        who are deemed to be repeat infringers. We may also, at our sole discretion, limit access to
        our products and services and/or terminate the accounts of any users who infringe the
        intellectual property rights of others, whether or not there is any repeat infringement.
      </p>

      <h2>5. No Inducement; Prohibited Use Disclaimer</h2>
      <p>
        Our products and services are provided for lawful purposes only.{' '}
        <strong>
          We do not authorize, encourage, induce, or condone the use of our products or services to
          infringe any copyright or other intellectual property right.
        </strong>
      </p>
      <p>By accessing or using our products or services, you agree that you will not:</p>
      <ul>
        <li>
          Use the products or services to reproduce, distribute, publicly perform, publicly display,
          or create derivative works of any copyrighted material without authorization from the
          rights holder or as otherwise permitted by law;
        </li>
        <li>
          Circumvent any technological measure that effectively controls access to a copyrighted
          work; or
        </li>
        <li>
          Use the products or services in any manner that violates the intellectual property rights
          or other rights of any third party.
        </li>
      </ul>
      <p>
        Our products and services are designed and intended for substantial non-infringing uses. We
        expressly disclaim any intent to facilitate, promote, or profit from copyright infringement.
        Any use of our products or services to infringe the rights of others is strictly prohibited,
        is undertaken solely at the user's own risk, and may result in suspension or termination of
        access as well as civil and/or criminal liability for the user under applicable law.
      </p>

      <h2>6. Modifications</h2>
      <p>
        We reserve the right to modify, update, or change the terms of this DMCA Copyright Policy at
        any time and at our sole discretion. Changes will be effective upon posting to this page,
        and the "Effective Date" above will be updated accordingly.
      </p>
    </PageShell>
  )
}
