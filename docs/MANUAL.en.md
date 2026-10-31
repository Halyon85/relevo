# Relevo user guide

Relevo keeps two places identical: the **hub**, the drive (or folder on your Mac) you work on at home, and the **portable drive**, the one you take with you. While both are connected, every change goes to the other side by itself. Away from home you work on the portable drive as usual and, when you come back, Relevo brings in what you did.

[Leer en español](MANUAL.md) · [Back to the start](../README.md)

**Contents**

1. [Before you start](#1-before-you-start)
2. [First run](#2-first-run)
3. [Day to day](#3-day-to-day)
4. [The menu bar menu](#4-the-menu-bar-menu)
5. [The panel screens](#5-the-panel-screens)
6. [What is copied and what isn't](#6-what-is-copied-and-what-isnt)
7. [Nothing is ever deleted for good](#7-nothing-is-ever-deleted-for-good)
8. [Encrypting the portable drive](#8-encrypting-the-portable-drive)
9. [Shortcuts and links](#9-shortcuts-and-links)
10. [What to do if…](#10-what-to-do-if)
11. [Updating Relevo](#11-updating-relevo)

---

## 1. Before you start

- **A Mac with Apple Silicon and macOS 14 or later.**
- **A portable drive formatted as APFS.** If it's exFAT or FAT (Windows formats), Relevo tells you: convert it to APFS in Disk Utility. Careful, that erases it: copy what it has first.
- **A backup.** Relevo is well tested, but it moves and replaces files. Don't trust it with your only copy.

The first time you open it, macOS asks for two permissions: **sending notifications** and **accessing removable volumes**. Both are needed.

## 2. First run

The first time you open Relevo, a three-step setup appears:

1. **Where do you work?** Choose the hub: a drive that stays at home, this Mac, or a folder on this Mac (for example, your Projects folder).
2. **Which drive do you take with you?** Choose the portable drive. If it doesn't show up, plug it in and click “Look for drives again”. To use the same drive for more than one thing (for example, projects and photos), tick “Save to a folder on the portable drive” and give it a name.
3. **Almost done.** Relevo offers to give the portable drive the hub's name when you're away (see [Same paths everywhere](#same-paths-everywhere)). Then you choose which folders sync.

That creates a **link**: a hub + portable drive pair. Then click “Sync now”. The first time it copies everything (it can take a while); after that, only what changes.

## 3. Day to day

### At home, with both drives

You don't have to do anything. Every change is copied within seconds (the **live copy**). The Home screen says “All up to date” when both sides have the same.

### When you leave

Two ways:

- **Eject the portable drive**, from Relevo or Finder. Since everything is already copied, that's enough.
- **“I'm leaving”**, in the menu or on Home. It copies whatever was still pending (seconds) and ejects the portable drive. When it says “Done: you can unplug it now”, unplug it.

If something is using the drive, Relevo closes background processes by itself. Apps with windows are listed: click “Close and eject” or close them yourself. Claude sessions open on the drive can be reopened from the app later.

### Away

Work on the portable drive as usual. If you gave it the hub's name, your projects are at the same path and your apps find them without changing anything. The menu says “Working from the portable drive”.

### When you come back

Plug in the portable drive. Relevo:

1. Renames the portable drive so it doesn't clash with the hub (nothing is unmounted).
2. Brings in what you did away, checking only what changed.

**Meanwhile, wait before opening your apps.** If it takes more than a few seconds you get the “Wait before opening your apps” notification, Home says “Wait a moment” and the menu bar icon moves. When it's done you get “Done, you can open your apps now”, with what came in.

If you opened an app on the drive too early (for example, Claude) and it ended up working on the portable drive, Relevo tells you: “Close Claude for a moment”. Once you close it, Relevo finishes sorting out the drives and you get the “Done” notification so you can open it again. That way it never ends up working on the wrong drive.

### Same paths everywhere

- **Away**, the portable drive has the same name as the hub. Your projects are at `/Volumes/<hub name>/…`, just like at home.
- **At home** it's called “<name> (portable)”, so two drives never share a name and it doesn't matter which one the Mac mounts first.
- At home, Relevo can **hide the portable drive from Finder** so you only see one (choose it in Drives). Open it from Relevo's menu with “Show the portable drive in Finder”.

## 4. The menu bar menu

Click Relevo's icon to see, for each link:

- **The status:** “All up to date”, “Copying 3 of 10…”, “Checking…”, “Needs your OK”, “Paused until 18:00”, etc.
- **Sync now:** checks what changed and copies it.
- **I'm leaving (copy and eject).**
- **Show the portable drive in Finder**, when it's hidden.
- **Pause:** for 1 hour, until tomorrow or until you resume it. “Resume” turns it back on.

At the bottom:

- **Eject drives:** all at once or one by one. Before ejecting a portable drive, it copies whatever is pending.
- **Open Relevo…**, **History** and **Quit Relevo**.
- **Check for Relevo updates…**, only in builds published by Halyon Team (see [Updating Relevo](#11-updating-relevo)).

## 5. The panel screens

### Home

- **At the top:** the status at a glance, with both drives (“Stays at home” and “Goes with you”), their free space and when the last copy was.
- **Buttons:** “Sync now”, “I'm leaving” and “Stop” (while copying).
- **What needs your OK** (see [Deleting a whole project](#deleting-a-whole-project)).
- **Files with two versions**, if there were conflicts.
- **Recent activity**, with a link to the full history.
- **Useful warnings:** for example, if you carry secrets (`.env`) on an unencrypted portable drive, or if a project is missing its dependencies on that drive (it gives you the commands to install them).

### What syncs

Two parts:

- **Folders that sync.** Tick the folders you want identical on both drives. They go with everything inside, hidden files too (`.env`, `.git`), at the same path. Whatever you don't tick stays only on its drive. You can open a folder and pick only some of its subfolders. Each one shows its size and number of files, and at the bottom you see whether it fits on the portable drive.
- **Never synced.** The rules in [What is copied and what isn't](#6-what-is-copied-and-what-isnt): dependencies, build output, what git ignores and whatever you add with “Add folder or file…”. Untick a rule to sync it again; “Restore the suggested list” puts everything back as it was.

### Drives

- **Your links:** each link with its hub and portable drive, whether they're connected and their free space. “Add another link” adds another pair (for example, photos on another drive). “Remove link” stops syncing that pair; it doesn't delete anything from any drive.
- **The name away:** “Use “<name>” when away” gives the portable drive the hub's name.
- **At home, hide the portable drive from Finder.**
- **Portable drive encryption** (see [Encrypting the portable drive](#8-encrypting-the-portable-drive)).
- **Deep check:** compares the contents of every file, not just date and size, to find damaged copies. It's slow because it reads everything. If it finds differences, it offers to copy those files again from the hub.
- **Eject drives:** every external drive connected, from any link.

### History

- **Activity:** what was copied, where and when. You can search for a file or folder. From each entry you can **recover** something deleted or **restore the previous version** of a replaced file.
- **Two versions:** pending conflicts (see [The same file changed on both sides](#the-same-file-changed-on-both-sides)).
- **Relevo Trash:** opens each drive's trash in Finder.
- **Clear history:** clears the list. It doesn't touch any file.

### Repositories

For people who work with git:

- **Clone from a link** (GitHub, GitLab, Bitbucket…) or from your GitHub list, if the `gh` tool is installed and signed in. Choose whether it goes **to the hub** (Relevo copies it to the portable drive) or **straight to the portable drive** (Relevo copies it to the hub). If the folder already exists, it isn't overwritten. Relevo stores no passwords: it uses your usual credentials.
- **Your repositories:** Relevo looks for git folders one level inside each synced folder and shows which ones have uncommitted changes, unpushed commits or are behind.
- **Check for updates** asks each remote whether there are new commits (`git fetch`); it doesn't change your files. **Pull** brings in the new commits only if nothing needs merging (`git pull --ff-only`).
- **Details:** open it in Finder or Terminal, see the changes, commit, merge branches or hide it from the list. Hidden ones are still copied.

If git isn't installed, Relevo tells you how to install it.

### General

- **Automatic:**
  - Sync automatically when plugged in.
  - Live copy.
  - Open at login.
- **Checks:**
  - **Daily full check**, overnight or when you're not using the Mac. “Check everything now” runs it right away.
  - **Monthly deep check**, with the Mac on power, both drives connected and not in use for a while. It only tells you if it finds something.
  - **Before the Mac sleeps**, it copies whatever is pending (it doesn't eject).
- **Shortcuts:** turn on the keyboard shortcuts and see the `relevo://` links.
- **Relevo Trash:**
  - How many days to keep what was deleted or replaced: 3, 7, 30 or 90.
  - **Empty now**, which shows how much space it takes and asks you to confirm.
- **Appearance:**
  - Theme: light, dark or the Mac's.
  - Language: Spanish, English or the Mac's.

## 6. What is copied and what isn't

**Everything in the folders you ticked is copied**, including hidden files like `.env` and `.git`.

**Never copied:**

- macOS's own files (`.DS_Store`, trash folders, Spotlight indexes) and git lock files: they last an instant and are recreated by themselves.
- **Build output and caches**, which are rebuilt by themselves: `.next`, `.nuxt`, `.turbo`, `.expo`, `.build`, `DerivedData`, `.gradle`, `.parcel-cache`, `.svelte-kit`, `__pycache__`.
- Any folder named **“Cosas mías”** (Spanish for “my stuff”), wherever it is: use it to keep something that shouldn't go to the other drive.
- Whatever you add in “Never synced”.

**Your choice:**

- **Dependencies** (`node_modules`, `.pnpm-store`, `.venv`, `venv`, `Pods`). By default they **are copied**, so your projects work away from home without downloading them again (with the same paths they work as is). If you turn them off they take less space, but you'll have to install them again away from home.
- **What git ignores:** what each project's `.gitignore` leaves out (`dist`, `coverage`, logs…). Copied by default. `.env` files are always copied.

**Whatever is running waits.** A database, an Android emulator or a virtual machine (UTM, VMware, Parallels, VirtualBox) change nonstop while they run, and a copy taken at that moment would be half-written. Relevo leaves them alone while they're running and copies them once when you close them.

## 7. Nothing is ever deleted for good

- **What's deleted or replaced doesn't disappear.** When you delete something on one drive, it isn't fully deleted on the other: it goes to that drive's **Relevo Trash** (a hidden folder, `.Relevo/Papelera`). When a file is replaced by a newer one, the old version goes there too.
- **How long it stays:** you choose in General (3, 7, 30 or 90 days); after that, it's deleted by itself. Of very large files (256 MB or more) only the last version is kept, so the drive doesn't fill up.
- **How to get something back:** from **History**, with “Recover” or “Restore previous”.
- **Empty it right away:** **General → Relevo Trash → Empty now**. What was in the trash can no longer be recovered; your files aren't touched.

### Deleting a whole project

If you delete (or move) a whole folder on one drive, Relevo **doesn't delete it from the other one without asking**. Home shows “Needs your OK”, with the list:

- **“Yes, continue”:** removes it from the other drive too (it goes to the Relevo Trash).
- **“Not now”:** doesn't touch anything.
- **If you don't answer**, it's applied by itself after 3 days. What was deleted stays in the trash.

### The same file changed on both sides

If you changed the same file differently on the hub and on the portable drive, Relevo **keeps both versions**: the newer one keeps its name and the other one sits next to it on both drives, named “name (conflicto hub …)” or “name (conflicto portátil …)” with the date (Spanish for “conflict”). In **History → Two versions** you choose which one stays (“Keep the hub version”, “Use the other one”) or, if you already fixed it by hand, “I've resolved it”.

### Repositories with different commits on each drive

If a project has different commits on the hub and on the portable drive, Relevo **doesn't touch its `.git` folder** (so the histories don't mix) and tells you to merge them with git. The rest of the files keep syncing.

### If you unplug the drive mid-copy

Each file is written under a temporary name and renamed at the end, and a journal remembers what was just written. So if you yank the drive, next time Relevo repairs whatever was half-done instead of treating it as your deletion. After an unplug like that, it checks everything just in case.

## 8. Encrypting the portable drive

If you lose the portable drive, anyone can read what's on it, including your projects' secrets. Encrypting it is optional and done from **Drives → Portable drive encryption → Encrypt…**:

1. Relevo explains what will happen.
2. It shows you the **drive's password**: simple words, no accents, so you can type it on any keyboard. Copy it to the Passwords app (“+” button, name “Disco <name>”) or write it on paper that doesn't travel with the drive.
3. To confirm you saved it, it asks for the **last word**.
4. It encrypts in the background: you can keep using the drive and close the window. If you unplug it halfway, it continues next time.

Nothing changes on this Mac: the password stays in the Keychain and Relevo unlocks the drive by itself every time you plug it in. On another Mac it asks for the password. To see it again, “Show password” asks for Touch ID or your Mac's password.

If you lose the password and it isn't anywhere, what's on the portable drive can't be recovered. But the hub has everything: erase the portable drive and Relevo fills it again.

## 9. Shortcuts and links

**Keyboard shortcuts**, turned on in General:

| Shortcut | Does |
|---|---|
| ⌃⌥⌘S | Sync |
| ⌃⌥⌘L | I'm leaving |
| ⌃⌥⌘E | Eject drives |

**`relevo://` links**, for macOS Shortcuts, Raycast or Alfred:

| Link | Does |
|---|---|
| `relevo://sincronizar` | Syncs what changed |
| `relevo://mevoy` | Copies the last changes and ejects the portable drive |
| `relevo://expulsar` | Ejects the drives |
| `relevo://pausar?horas=1` | Pauses for the number of hours you give |
| `relevo://reanudar` | Turns copying back on |

English aliases work too: `sync`, `leave`, `eject`, `pause?hours=1`, `resume`. “I'm leaving”, eject and resume ask you to confirm before doing anything, because any web page could open a link like that. A pause from a link lasts 30 days at most.

## 10. What to do if…

**…the portable drive shows up with the hub's name at home (“The drives got swapped”).** It happens if the portable drive was mounted first. Meanwhile Relevo doesn't sync, so nothing goes to the wrong drive. Click **“Fix it”** on Home: it renames them without unmounting anything.

**…I can't eject the drive.** Relevo shows what's using it. Close it or click “Close and eject”. If macOS doesn't say what's using it, try again in a few seconds.

**…Relevo says “First copy pending”.** Click “Sync now”. The first time it copies everything and can take a while.

**…I can't find a file I deleted.** Go to **History**, search for it by name and click “Recover”. If more time has passed than you chose for the trash, it's gone.

**…I carry secrets (`.env`) on the portable drive.** Relevo warns you on Home. Encrypt the portable drive (see [Encrypting the portable drive](#8-encrypting-the-portable-drive)).

**…a project doesn't work away because its dependencies are missing.** Home shows a warning with the commands to install them (“Copy the commands”). To always take them along, leave dependencies on in “Never synced”.

**…I want a folder not to go to the other drive.** Add it in **What syncs → Never synced → Add folder or file…**, or name it “Cosas mías”.

**…I want to stop for a while.** Relevo's menu → **Pause** (1 hour, until tomorrow or until you resume it).

## 11. Updating Relevo

- **If you built it yourself:** pull the new code and build again.

  ```bash
  git pull && ./compilar.sh instalar
  ```

  Your settings, links and trash stay as they were.

- **If you downloaded it from [Releases](https://github.com/Halyon85/relevo/releases):** it updates itself. Relevo checks for new versions once a day and asks before installing. You can also check by hand from the menu with “Check for Relevo updates…”. New versions come signed: Relevo only installs the ones Halyon Team signed.

---

<p align="center">Developed by <a href="https://halyon.team"><b>Halyon Team</b></a> · Made in Argentina 🇦🇷</p>
