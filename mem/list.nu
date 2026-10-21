#!/usr/bin/env nu

# List all saved memories and topics to see what knowledge is stored
def main [] {
    let mem_dir = ($env.HOME | path join ".config" "ken" "_mem")
    mkdir $mem_dir
    let files = (glob ($mem_dir | path join "*.md"))
    if ($files | is-empty) {
        return "No saved memories found."
    }

    $files | each { |f|
        let name = ($f | path parse | get stem)
        let first_line = (open --raw $f | lines | first 1 | default "" | str substring 0..70)
        $"- ($name): ($first_line)"
    } | str join "\n"
}
