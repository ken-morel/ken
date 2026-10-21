#!/usr/bin/env nu

# Synchronize email accounts via mbsync and update notmuch index
def main [
    --all (-a)             # Sync all accounts (default)
    --account: string = "" # Specific account channel to sync
] {
    let mbsync_args = if ($account | is-empty) {
        ["-a"]
    } else {
        [$account]
    }

    let sync_res = (^mbsync ...$mbsync_args | complete)
    let notmuch_res = (^notmuch new | complete)
    $"mbsync output:\n($sync_res.stdout)\n($sync_res.stderr)\n\nnotmuch output:\n($notmuch_res.stdout)\n($notmuch_res.stderr)"
}
