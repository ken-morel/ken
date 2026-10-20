#!/usr/bin/env nu

# Read an email by thread ID, message ID, or query using notmuch
def main [
    id: string             # Thread ID (e.g. 'thread:0000000000003cbb'), message ID, or query
    --raw (-r)             # Output raw MIME source without parsing
] {
    if ("/dev/tty" | path exists) {
        $"\n[mail/read] ID: ($id)\n" | save --append "/dev/tty"
    }

    if $raw {
        return (^notmuch show --format=raw $id)
    }

    let script = '
import sys, subprocess, email
from email import policy

target = sys.argv[1]
try:
    proc = subprocess.run(["notmuch", "show", "--format=raw", target], capture_output=True, check=True)
except Exception as e:
    print(f"Error fetching email: {e}", file=sys.stderr)
    sys.exit(1)

if not proc.stdout.strip():
    print(f"No email found matching: {target}")
    sys.exit(0)

msg = email.message_from_bytes(proc.stdout, policy=policy.default)
print(f"Subject: {msg.get('subject', '(No Subject)')}")
print(f"From:    {msg.get('from', '(Unknown)')}")
print(f"To:      {msg.get('to', '')}")
if msg.get("cc"):
    print(f"Cc:      {msg.get('cc')}")
print(f"Date:    {msg.get('date', '')}")
print("-" * 50)

body_part = msg.get_body(preferencelist=("plain",))
if body_part:
    print(body_part.get_content())
else:
    html_part = msg.get_body(preferencelist=("html",))
    if html_part:
        html_content = html_part.get_content()
        try:
            p = subprocess.run(["cha", "-T", "text/html", "-d", "-M"], input=html_content.encode("utf-8", errors="ignore"), capture_output=True)
            rendered = p.stdout.decode("utf-8", errors="ignore")
            print(rendered if rendered.strip() else html_content)
        except Exception:
            print(html_content)
    else:
        print("(No text or HTML body found in message)")
'
    let res = (^python3 -c $script $id | complete)
    if ($res.exit_code == 0) {
        $res.stdout
    } else {
        $"Error reading email: ($res.stderr)"
    }
}
