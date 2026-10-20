#!/usr/bin/env nu

# Display current working directory
def main [] {
    let dir = ($env.PWD)
    if ("/dev/tty" | path exists) {
        $"\n[fs/cwd] ($dir)\n" | save --append "/dev/tty"
    }
    $dir
}
