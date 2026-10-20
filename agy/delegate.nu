#!/usr/bin/env nu

# Delegate a complex task, refactor, or coding project to Antigravity (agy)
def main [
    task: string                                  # Task description, requirements, or coding prompt
    --model (-m): string = "gemini-3.8-flash-low" # Antigravity model name
] {
    if ("/dev/tty" | path exists) {
        $"\n[agy/delegate] delegating to agy (model: ($model))\n" | save --append "/dev/tty"
    }

    let p = $"Perform this task directly. Be concise and high-density without conversational filler:\n\n($task)"
    let res = (^agy --model $model -p $p | complete)
    if ($res.exit_code == 0) {
        $res.stdout
    } else {
        $"Antigravity error: ($res.stderr)\n($res.stdout)"
    }
}
