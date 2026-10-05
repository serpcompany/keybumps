import Image from 'next/image'

/** The Keybumps app icon as an author's avatar: every plugin is made by Keybumps. */
export function KeybumpsAvatar({ size = 16 }: { size?: number }) {
  return <Image src="/brand/app-icon.png" alt="" width={size} height={size} className="avatar" />
}
