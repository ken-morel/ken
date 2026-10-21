#!/usr/bin/env nu

# Send a desktop notification using notify-send
def main [
    summary: string           # Notification title/summary
    body: string = ""         # Notification body text
    --urgency: string = "normal" # Urgency level (low, normal, critical)
] {
    let args = if ($body | is-empty) {
        [-u $urgency $summary]
    } else {
        [-u $urgency $summary $body]
    }

    let res = (^notify-send ...$args | complete)
    if ($res.exit_code == 0) {
        $"Notification sent: ($summary)"
    } else {
        $"Failed to send notification: ($res.stderr)"
    }
}
