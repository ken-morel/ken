#!/usr/bin/env nu

# List all academic course note files and their topic outline (= and == headings)
def main [
    --all (-a) # Include template and helper files
] {
    let notes_dir = ($env.HOME | path join "Documents" "notes")
    if not ($notes_dir | path exists) {
        return $"Notes directory not found at ($notes_dir)"
    }
    let typ_files = (glob ($notes_dir | path join "**" "*.typ"))
    let md_files = (glob ($notes_dir | path join "**" "*.md"))
    let all_files = ($typ_files | append $md_files | sort)

    mut output = []

    for f in $all_files {
        if ($f | path type) != "file" {
            continue
        }
        let base = ($f | path parse | get stem)
        let filename = ($f | path basename)
        if not $all and ($filename == "template.typ" or ($f | str contains "/.") or ($f | str contains "/assets/")) {
            continue
        }

        let rel = ($f | path relative-to $notes_dir)
        let lines_list = (open --raw $f | lines)
        let count = ($lines_list | length)

        mut headings = []
        for l in $lines_list {
            let trimmed = ($l | str trim)
            if ($trimmed | str starts-with "== ") {
                let h = ($trimmed | str substring 3..)
                $headings = ($headings | append $"    - ($h)")
            } else if ($trimmed | str starts-with "= ") {
                let h = ($trimmed | str substring 2..)
                $headings = ($headings | append $"  * ($h)")
            } else if ($trimmed | str starts-with "## ") {
                let h = ($trimmed | str substring 3..)
                $headings = ($headings | append $"    - ($h)")
            } else if ($trimmed | str starts-with "# ") {
                let h = ($trimmed | str substring 2..)
                $headings = ($headings | append $"  * ($h)")
            }
        }

        mut file_entry = $"=== ($rel) \(($count) lines\) ==="
        if not ($headings | is-empty) {
            $file_entry = ($file_entry + "\n" + ($headings | str join "\n"))
        }
        $output = ($output | append $file_entry)
    }

    $output | str join "\n\n"
}
