#!/usr/bin/env nu

# Synchronize email accounts via mbsync and update notmuch index
def main [
    --all (-a)             # Sync all accounts (default)
    --account: string = "" # Specific account channel to sync
] {
    if ("/dev/tty" | path exists) {
        $"\n[mail/sync] Starting email sync...\n" | save --append "/dev/tty"
    }

    let mbsync_args = if ($account | is-empty) {
        ["-a"]
    } else {
        [$account]
    }

    let sync_res = (^mbsync ...$mbsync_args | complete)
    let notmuch_res = (^notmuch new | complete)

    if ("/dev/tty" | path exists) {
        $"\n[mail/sync] Sync completed.\n" | save --append "/dev/tty"
    }

    $"mbsync output:\n($sync_res.stdout)\n($sync_res.stderr)\n\nnotmuch output:\n($notmuch_res.stdout)\n($notmuch_res.stderr)"
}
