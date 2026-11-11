# Security

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue:

- GitHub: **Security → Report a vulnerability** on this repository (a private advisory only the
  maintainers can see).

Include what you found, how to reproduce it, and the SilkNest version (menu bar spider → About).
You'll get a reply within a few days. Please give us a reasonable time to ship a fix before disclosing.

## What SilkNest stores

Everything stays on your Mac, in `~/Library/Application Support/SilkNest`:

| What | File(s) |
|---|---|
| Clipboard history (up to 1000 items) | `History/order.enc`, `History/<id>.meta.enc` (metadata, text read from images, thumbnail), `History/<id>-<n>.enc` (content) |
| Silk Notes | `Notes.enc` |
| The encryption key | `.history.key` |

Settings live in the usual macOS preferences (`studio.webber.spider`).

## How it is protected

- **Encrypted at rest:** every history and notes file is encrypted with AES-256-GCM using a random
  256-bit key created on your Mac. The key is a separate file; nothing is written without it.
- **Owner-only:** the folder is `0700` and files are `0600`, so other accounts on the Mac can't read them.
- **Not in backups:** the folder is excluded from Time Machine and other backups, so a backup disk never
  holds the key next to the data it unlocks.
- **Never caught:** copies that the source app marks as concealed or transient (password managers do).
- **Memory only, never written:** copies from known password managers, and detected secrets — API keys and
  tokens, private keys, card numbers, one-time codes — in copied text **and in the text of screenshots and
  images**. Secrets are shown masked or blurred and removed after two minutes unless pinned.
  A new image is not written to disk until its text has been read and checked.
- **Deletion:** removing an item or clearing the history deletes its files, including text read from
  screenshots. Uninstall (Settings) can delete everything.

## Network

SilkNest makes exactly one kind of network request: it fetches `https://silknest.app/version.json` (and,
when there is an update, the update zip) — 20 seconds after launch, every 3 hours and after waking.
Nothing about you or your clipboard is sent.

An update is installed only if:
1. `version.json` carries a valid Ed25519 signature from the SilkNest release key (only the public half is
   in the app);
2. the version is newer than the installed one;
3. the zip comes from silknest.app over HTTPS and matches the signed SHA-256;
4. the app inside passes a strict code-signature check against the installed app's own designated
   requirement — builds signed with the "SilkNest Signing" certificate accept only updates signed with it.

## Permissions

- **Accessibility** (optional): only to press ⌘V for you (1-click paste) and to find the text caret. No
  keystrokes or screen contents are recorded. Copying works without it.
- **Files & Folders** (Desktop or your screenshot folder): only to catch screenshots you save.
- No Screen Recording, no Full Disk Access, no microphone or camera.

## Code signing and notarization

Releases are signed with a self-signed "SilkNest Signing" certificate (stable across versions) with the
hardened runtime. They are **not notarized by Apple** yet, so the first launch needs System Settings →
Privacy & Security → Open Anyway. Verify a download with the SHA-256 published with each release.
