#!/usr/bin/env nu

# List all saved memories and topics to see what knowledge is stored
def main [] {
    let mem_dir = ($env.HOME | path join ".config" "ken" "_mem")
    mkdir $mem_dir

    if ("/dev/tty" | path exists) {
        $"\n[mem/list] checking memories in ($mem_dir)\n" | save --append "/dev/tty"
    }

    let files = (ls ($mem_dir | path join "*.md") | default [])
    if ($files | is-empty) {
        return "No saved memories found."
    }

    $files | each { |f|
        let name = ($f.name | path parse | get stem)
        let first_line = (open --raw $f.name | lines | first 1 | default "" | str substring 0..70)
        $"- ($name): ($first_line)"
    } | str join "\n"
}
