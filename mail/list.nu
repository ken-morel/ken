#!/usr/bin/env nu

# List the latest emails using notmuch with optional pagination
def main [
    --limit (-n): int = 10       # Number of emails to list
    --offset (-o): int = 0       # Number of emails to skip for pagination (e.g. 5 to view 6-10)
    --query (-q): string = "*"   # Search query or filter
    --unread (-u)                # Filter only unread messages
] {
    let q = if $unread { $"tag:unread ($query)" } else { $query }
    let res = (^notmuch search --sort=newest-first --offset=($offset | into string) --limit=($limit | into string) $q | complete)
    if ($res.exit_code == 0) {
        $res.stdout
    } else {
        $"Error querying emails: ($res.stderr)"
    }
}
