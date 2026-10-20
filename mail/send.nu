#!/usr/bin/env nu

# Send an email using msmtp
def main [
    to: string                  # Recipient email address
    subject: string             # Email subject line
    body: string                # Email body text
    --account (-a): string = "engon" # Account to send from (engon, devsafe, engoncnz, gmail1, gmail2)
    --from (-f): string = ""    # Sender email address override
    --cc (-c): string = ""      # CC recipient
] {
    if ("/dev/tty" | path exists) {
        $"\n[mail/send] to: ($to) | subject: ($subject) | account: ($account)\n" | save --append "/dev/tty"
    }

    let sender = if ($from | is-empty) {
        match $account {
            "engon" => "me@engon.cm"
            "devsafe" => "ama@devsafe.cm"
            "engoncnz" => "engon@cynozalabs.cm"
            "gmail1" => "engonken8@gmail.com"
            "gmail2" => "engonkenmorel@gmail.com"
            _ => "me@engon.cm"
        }
    } else {
        $from
    }

    let date_str = (^date -R | str trim)
    let domain = ($sender | split row "@" | last)
    let rand_val = (random int 1..9999 | into string)
    let msg_id = $"<($date_str | hash sha256).($rand_val)@($domain)>"

    mut headers = [
        $"From: ($sender)"
        $"To: ($to)"
    ]
    if not ($cc | is-empty) {
        $headers = ($headers | append $"Cc: ($cc)")
    }
    $headers = ($headers | append [
        $"Subject: ($subject)"
        $"Date: ($date_str)"
        $"Message-ID: ($msg_id)"
        "MIME-Version: 1.0"
        "Content-Type: text/plain; charset=UTF-8"
        "Content-Transfer-Encoding: 8bit"
    ])

    let full_msg = $"($headers | str join "\n")\n\n($body)\n"
    
    let args = if ($cc | is-empty) {
        [-a $account $to]
    } else {
        [-a $account $to $cc]
    }

    let res = ($full_msg | ^msmtp ...$args | complete)
    if ($res.exit_code == 0) {
        $"Email sent successfully to ($to) via account ($account) (From: ($sender))."
    } else {
        $"Failed to send email: ($res.stderr)"
    }
}


