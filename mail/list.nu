#!/usr/bin/env nu

# List the latest emails using notmuch
def main [
    --limit (-n): int = 10       # Number of emails to list
    --query (-q): string = "*"   # Search query or filter
    --unread (-u)                # Filter only unread messages
] {
    let q = if $unread { $"tag:unread ($query)" } else { $query }
    if ("/dev/tty" | path exists) {
        $"\n[mail/list] query: '($q)' | limit: ($limit)\n" | save --append "/dev/tty"
    }
    let res = (^notmuch search --sort=newest-first --limit=($limit | into string) $q | complete)
    if ($res.exit_code == 0) {
        $res.stdout
    } else {
        $"Error querying emails: ($res.stderr)"
    }
}
