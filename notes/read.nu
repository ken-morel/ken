#!/usr/bin/env nu

# Read raw contents or a specific section of an academic course note file
def main [
    note: string            # Note filename or subject (e.g. analysis, operating-systems)
    --section (-s): string = "" # Optional heading to isolate (e.g. 'Integrals', 'Process Management')
    --lines (-n): int = 300 # Maximum lines to output
] {
    let notes_dir = ($env.HOME | path join "Documents" "notes")
    
    mut target_file = ($notes_dir | path join $note)
    if not ($target_file | path exists) {
        let matches = (glob ($notes_dir | path join $"*($note)*.typ"))
        if not ($matches | is-empty) {
            $target_file = ($matches | first)
        } else {
            let md_matches = (glob ($notes_dir | path join $"*($note)*.md"))
            if not ($md_matches | is-empty) {
                $target_file = ($md_matches | first)
            } else {
                return $"Note '($note)' not found in ($notes_dir)."
            }
        }
    }
    let all_lines = (open --raw $target_file | lines)
    if ($section | is-empty) {
        let selected = ($all_lines | slice 0..$lines)
        return ($selected | str join "\n")
    }

    # Filter section
    mut inside_section = false
    mut section_lines = []
    let target_lower = ($section | str lowercase)

    for l in $all_lines {
        let trimmed = ($l | str trim)
        let is_heading = ($trimmed | str starts-with "=") or ($trimmed | str starts-with "# ")
        if $is_heading {
            if ($trimmed | str lowercase | str contains $target_lower) {
                $inside_section = true
                $section_lines = ($section_lines | append $l)
                continue
            } else if $inside_section {
                break
            }
        }
        if $inside_section {
            $section_lines = ($section_lines | append $l)
        }
    }

    if ($section_lines | is-empty) {
        $"Section '($section)' not found in ($target_file | path basename)."
    } else {
        $section_lines | slice 0..$lines | str join "\n"
    }
}
