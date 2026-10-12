# Vault encryption

Status: in 1.1.1 (unreleased). Off by default. Settings › Vault › Encryption.

The Vault is a folder, `<storage>/Vault`, normally `~/RoachNet/storage/Vault`. Turning encryption on keeps everything in that folder inside an encrypted disk image. Only the recovery key, or this Mac's saved copy of it, opens the image. RoachNet never turns encryption on or off by itself.

## What it uses

- **The disk image.** macOS's `hdiutil` makes an APFS sparse bundle with AES-256 encryption. It grows as files are added, up to 1 TB, and only takes the space its files use. RoachNet doesn't implement a cipher. Passphrases reach `hdiutil` over stdin, never on a command line.
- **The recovery key.** 256 random bits from `SecRandomCopyBytes`, written as 52 Crockford base32 characters in 13 groups of four. It is the image's passphrase. Typing is forgiving: any case, spaces or dashes, O for 0, and I or L for 1.
- **The saved key** (optional, on by default in setup). The same key is kept in the login Keychain as a generic password, readable only while the Mac is unlocked, on this Mac only. With it, RoachNet can unlock the Vault when it opens.
- **Copy checks.** CryptoKit's SHA-256 is used for checking copies, nothing else.

## Locked and unlocked

- **Unlocked.** The image is mounted over `<storage>/Vault`. Everything that reads the Vault sees the same paths and files as before: the app, the runtime, Finder, Quick Look and other apps. Spotlight is told not to index the volume (`.metadata_never_index`), and the volume stays out of the Finder sidebar.
- **Locked.** `<storage>/Vault` is an empty, read-only folder holding one file, `.roachnet-vault-locked`.
  - Nothing can write into it by mistake.
  - The runtime reports the Vault as locked: `GET /api/rag/files` returns no files with `vaultLocked: true`, `GET /api/companion/vault` has `locked: true`, and the readiness check counts a locked Vault as ready.
  - If anything does end up in that folder, unlocking refuses to mount over it, so nothing is hidden.
- **Options.** "Unlock with this Mac's saved key when RoachNet opens" and "Lock when RoachNet quits" are both on by default. Locking fails while another app has Vault files open; quit that app first.

## What it protects

Everything in the Vault folder:

- Shelf files;
- RoachBrain memory and wiki;
- Dev Studio projects kept in the Vault;
- the list of saved secrets (names only; their values are in the Keychain);
- the list of linked Obsidian vaults.

These are protected while the Vault is locked or the Mac is off, and in any copy of the storage folder, such as a Time Machine backup, a synced folder or a copied drive. Anyone with those files sees one encrypted disk image.

## What it doesn't protect

- The Vault while it's unlocked. Apps running as you can read it, as with any folder.
- Obsidian vaults kept outside the Vault (RoachNet only links to them).
- Roach's Archive, RoachClaw chat history, models, settings and logs, which all live outside the Vault.
- Copies you export, or files you open in other apps that keep their own copies.
- The unencrypted original, until you remove it (see below). On an SSD, deleted data can stay readable until the drive reuses the space; FileVault protects against that.
- Anyone who has your recovery key, or your Mac login while the saved key is in the Keychain.

FileVault encrypts the whole disk. Vault encryption adds protection for copies of the storage folder, for other accounts on the Mac, and for the time the Vault is locked while you're logged in.

## Recovery

- **The recovery key is the only way in when the saved key is gone,** for example on a new Mac, after a Keychain reset, or if you chose not to save it. Setup asks you to save the key (to a file or a password manager) and to type its last four characters before anything moves.
- **RoachWares never sees the key and can't recover it.** Lose the key and the saved copy, and nobody can open the Vault.

## Turning it on

1. **Check.** RoachNet counts the Vault's files and checks for free space: the Vault's size plus a fifth, plus 1 GB.
2. **Copy.** It records `encrypting / copying` in `<storage>/.vault-encryption/state.json`, makes the image, mounts it at a staging folder, and copies each item with `ditto`, which keeps extended attributes, resource forks and permissions. Links are copied as links.
3. **Verify.** Every path, size, link target and SHA-256 in the copy has to match the original. The original is scanned again to make sure nothing changed during the copy. If anything doesn't match, the image is deleted and the Vault is left exactly as it was.
4. **Swap.** It records `encrypting / swapping`, moves the original to `<storage>/.vault-encryption/Vault-unencrypted-<time>` (a rename on the same drive), puts the locked folder in its place, records `encrypted / done`, and mounts the image.
5. **Original kept.** The unencrypted original stays until you remove it in Settings. Settings keeps showing it as a warning until then.

## Turning it off

The Vault must be unlocked.

1. **Copy.** RoachNet records `decrypting / copying` and copies the files out into `<storage>/.vault-encryption/Vault-decrypted-<time>`.
2. **Verify.** The copy is checked the same way as when turning encryption on.
3. **Swap.** RoachNet records `decrypting / swapping` and closes the image. It removes the locked folder and moves the plain copy into place. The image moves to `Vault-encrypted-<time>.sparsebundle`.
4. **Old image kept.** The old image stays until you remove it in Settings. Removing it also deletes the saved key.

## If a move is cut off

A crash, a forced quit or a power cut can stop a move partway. The next time RoachNet opens, it reads the state file and does one of these. Settings also has a "Finish or Undo the Move" button.

| Stopped during | What happens | Why it's safe |
| --- | --- | --- |
| Turning on, before the swap | The half-made image is deleted. | The Vault was never touched. |
| Turning on, during the swap | Finished. The Vault opens with the key. | The original had already been moved aside and is kept. |
| Turning off, before the swap | The half copy is deleted. | The Vault is still encrypted. |
| Turning off, during the swap | Finished. The plain copy, already checked, becomes the Vault. | The image is kept. |

At no step is the only copy of a file deleted. Originals are removed only when you ask.

## Code and tests

- **`native/macos/Sources/RoachNetCore/VaultEncryption*.swift`**:
  - `VaultEncryptionManager` handles the moves and recovery.
  - `HdiutilDiskImageTool`, `KeychainVaultKeyStore` and `VaultRecoveryKey` do the disk image, Keychain and key work.
  - `VaultInventory` does the copy checks.
- **`native/macos/Sources/RoachNetApp/VaultEncryption{Section,Sheets}.swift`** hold the Settings section, the setup and unlock sheets, and the launch and quit hooks.
- **`native/macos/Tests/RoachNetAppTests/VaultEncryptionTests.swift`** runs against real encrypted images in throwaway folders:
  - a round trip on, lock, unlock, off, with every file, link and extended attribute checked;
  - a wrong key, and a missing saved key;
  - a write into the locked folder, and stray files blocking an unlock;
  - all four interruption points;
  - a one-byte difference caught by the copy check.

  Set `ROACHNET_SKIP_DISK_IMAGE_TESTS=1` to skip them on a machine without `hdiutil`.

## Not done yet

- **Unlocking doesn't ask for Touch ID or the login password.** The saved key's Keychain item is readable while the Mac is unlocked, so the saved key protects against other accounts and copies, not against apps running as you.
- **The Vault can't be resized.** At the 1 TB ceiling, it would need `hdiutil resize`.
- **There's no rekeying.** You can't change the recovery key without turning encryption off and on again.
