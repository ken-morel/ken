#!/usr/bin/env nu

# Execute a shell command and return stdout/stderr
def main [
    command: string       # Shell command line to execute
    --timeout (-t): int = 30 # Execution timeout in seconds
] {
    if ("/dev/tty" | path exists) {
        $"\n[code/exec] running: ($command)\n" | save --append "/dev/tty"
    }

    let res = (^timeout --kill-after=2 ($timeout | into string) bash -c $command | complete)
    mut out = if ($res.stdout | is-empty) { $res.stderr } else { $res.stdout }
    if ($out | str length) > 4000 {
        $out = ($out | str substring 0..4000) + "\n...[truncated]"
    }
    $out
}
