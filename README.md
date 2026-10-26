# Claude Desktop account switcher for PowerShell

A **terminal-only PowerShell tool for the Code tab in Claude Desktop on Windows**. No GUI and no Claude CLI login. Run `./ClaudeSwitcher.ps1` for the text menu, or use the commands below. `Start.cmd` opens the same terminal menu.

Run `./Install.ps1` to install the runtime under `%LOCALAPPDATA%\Programs\ClaudeSwitcher` and create `%USERPROFILE%\.local\bin\claude-switcher.cmd` on your user PATH. Then use `claude-switcher`, `claude-switcher Add Work`, or `claude-switcher Switch Personal` from any directory. The installer keeps the source project and saved accounts in place. Run it again to install source updates.

It keeps the existing Desktop profile and shared `.claude` configuration. It saves only Desktop authentication cookies, opaque encrypted OAuth caches, account identity metadata, and the cookie encryption-key fingerprint. Local Code session descriptors are synchronized into the selected account's registry so the same local conversations and project folders can be resumed.

## Set up accounts

Close Claude Desktop completely, including its tray icon, before each command that changes files. Stop running Code sessions first. The tool refuses to stop or kill apps automatically.

```powershell
# Save the Desktop account you are already signed into.
.\ClaudeSwitcher.ps1 Save Personal

# Register a different account without revoking Personal's saved login.
.\ClaudeSwitcher.ps1 Add Work

# Switch later, with Claude closed.
.\ClaudeSwitcher.ps1 Switch Personal
.\ClaudeSwitcher.ps1 Switch Work

# Inspect accounts and detected Desktop storage.
.\ClaudeSwitcher.ps1 List
.\ClaudeSwitcher.ps1 Doctor
```

`Add` temporarily removes only local authentication, then prompts you to open Claude Desktop and sign into the other account. Open the Code tab once so Desktop writes the account/organization identity. Quit Claude completely and press Enter in PowerShell. The new login is captured, and the local Code sessions are made visible to it. Reopen Desktop and resume the conversation.

**Do not use Desktop Logout to register accounts.** The installed app calls the server's logout endpoint to revoke the web session. A previously saved snapshot cannot undo that revocation. Add uses an offline local reset and retains an encrypted cancellation backup instead.

For separate commands instead of waiting at a prompt:

```powershell
.\ClaudeSwitcher.ps1 PrepareLogin Work
# Open Desktop, sign in to Work, open Code, and quit Desktop.
.\ClaudeSwitcher.ps1 FinishLogin
# Or restore the previous login if you cancel registration:
.\ClaudeSwitcher.ps1 CancelLogin
```

## What stays shared

- Desktop preferences, MCP configuration, repository/worktree files, and installed extensions stay in the existing profile.
- The tool leaves Chromium Local Storage, IndexedDB, shared `.claude` settings, project transcripts, file history, memory, and workspace files in place.
- Only `oauth:tokenCache`, `oauth:tokenCacheV2`, and `lastKnownAccountUuid` change in Desktop `config.json`. Only `oauthAccount` changes in the shared `.claude.json`.
- Only Claude authentication and `lastActiveOrg` cookies are replaced; other browser cookies remain intact. Chromium's encryption key in `Local State` is never replaced.
- Local `claude-code-sessions/<account>/<organization>/local_*.json` descriptors are mirrored to the selected account, retaining their session IDs, project paths, worktree paths, and other fields. The newest record wins by `lastActivityAt`, then modification time. Tombstones in the destination are respected. Source records and shared transcripts remain intact.

Run `SyncSessions` after saving the current account if you want to make sessions from other account directories visible without changing credentials.

```powershell
.\ClaudeSwitcher.ps1 SyncSessions
```

This shares **local Code sessions**. Cloud chats, cloud projects, server-owned workspace memberships, Cowork sessions, scheduled tasks, SSH sessions, and server-synced sidebar groups are not migrated. Desktop may fetch different sidebar groups and account-specific server settings after login; this tool cannot promise identical server-synced sidebar organization. Sharing local files does not transfer ownership of cloud data. Switching requires quitting and reopening Desktop; an in-flight response cannot change accounts. Check Desktop's account indicator before continuing. Each account keeps its own usage limits.

### Preserved thinking after switching organizations

Desktop may report **"Claude can't use thinking from another organization"** when you resume a shared session. This is a service-side check on the thinking block's signed account binding, not a corrupted local session. For account-bound thinking blocks, the service drops foreign-account reasoning from the request while allowing the conversation to continue. Claude may need to generate new reasoning, increasing latency and token use. The original blocks remain available when you resume under the account/organization that produced them.

The switcher preserves conversation records and shared project files, but cannot make these protected thinking blocks reusable under another organization. It leaves thinking blocks and signatures intact. A short progress summary before switching can help Claude reconstruct the task: ask it to record the goal, decisions, files changed, test results, blockers, and next steps as ordinary response text. This does not preserve private thinking or guarantee the same token cost. See [Anthropic's account-bound preserved-thinking documentation](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking#thinking-blocks-stay-with-the-account-that-produced-them).

## Storage, recovery, and compatibility

Windows PowerShell 5.1 and PowerShell 7 are supported. The tool uses the Windows-provided `winsqlite3.dll` to read/write Desktop's cookie database; `DesktopSqlite.cs` is loaded with PowerShell's `Add-Type`. No Node.js, SQLite download, GUI toolkit, or CLI installation is required.

Accounts are encrypted with Windows DPAPI under `%LOCALAPPDATA%\ClaudeDesktopSwitcher\desktop-accounts.dpapi`. Saved cookies are tied to the existing Desktop Chromium encryption key and the Windows user/machine. If the key changes, the tool refuses to restore the old cookies. Saved sessions may expire or be revoked by the service; register again under a new label when necessary. Token caches are copied as opaque encrypted strings and are never decrypted or printed.

New encrypted files use a versioned DPAPI byte envelope so large config/recovery backups are supported. Existing accounts saved in the original SecureString format remain readable and are upgraded when subsequently saved; no reset or account re-registration is required.

The outgoing login is captured again before switching to retain refreshed authentication. Changes use an encrypted recovery journal and SQLite transactions. If interrupted, run `Recover` after closing Claude. Recovery restores the previous state only when current files/cookies match the journal's before/after versions; unexpected newer changes stop recovery. Keep `recovery.dpapi` if recovery reports a conflict. `CancelLogin` can restore the previous saved login after an interrupted account-registration flow, while preserving non-authentication preferences changed during login.

```powershell
.\ClaudeSwitcher.ps1 Recover
.\ClaudeSwitcher.ps1 Remove Work # Removes saved copy only; live login stays in place.
.\ClaudeSwitcher.ps1 Switch Work -WhatIf # Shows the intended action without changing files.
```

Profiles are detected under `%APPDATA%\Claude`, `%LOCALAPPDATA%\Claude`, `%LOCALAPPDATA%\Claude-Data\claude_*`, and the Microsoft Store location `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude`. Each candidate must contain `config.json`. If more than one profile exists, select it explicitly:

```powershell
.\ClaudeSwitcher.ps1 Doctor -DesktopDataDirectory 'C:\path\to\Claude'
```

`-GlobalConfigPath`, `-StoreDirectory`, and `-OrganizationId` are available for deliberate overrides. A vault is bound to its original Desktop profile and global-config path. `-OrganizationId` is needed only if Desktop has not written matching global identity metadata; the tool never guesses an organization from old directory names.

The Desktop storage format is internal and may change in future releases. Implementation was checked against the locally installed Windows Store Claude **2.9939.4.0**. Actual switching between live accounts still needs validation through your Desktop sign-ins; tests use fake accounts, cookies and sessions. No real account has been switched during development.

Run the isolated regression suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Core.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Storage.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Discovery.Tests.ps1
```

References: [official Desktop Code documentation](https://code.claude.com/docs/en/desktop) and [account-partitioned Desktop session storage reported in Anthropic's issue tracker](https://github.com/anthropics/claude-code/issues/85294). The installed Desktop source and local file schemas supplied the Windows cookie/cache implementation details. `tools/Inspect-Desktop.cjs` is an optional read-only archive inspection helper used in development, not a runtime dependency.
