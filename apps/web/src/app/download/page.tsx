import type { Metadata } from 'next';
import { getLatestRelease } from '../../lib/latest-release';

export const metadata: Metadata = {
  title: 'Download Keybumps',
  description: 'Download the latest Keybumps beta for macOS.',
  robots: { index: false, follow: false },
};

// Re-read the release pointer at most every five minutes.
export const revalidate = 300;

export default async function DownloadPage() {
  const release = await getLatestRelease();
  return (
    <main>
      <h1>Download Keybumps</h1>
      <p>Latest beta: {release.version}</p>
      <p>
        <a href={release.dmgURL}>Download Keybumps for macOS</a>
      </p>
    </main>
  );
}
