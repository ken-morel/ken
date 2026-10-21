#!/usr/bin/env nu

# Search across all student lecture notes for keywords, formulas, or concepts
def main [
    query: string         # Keyword, formula, or concept to search for
    --limit (-n): int = 8 # Maximum matches to display
] {
    let notes_dir = ($env.HOME | path join "Documents" "notes")
    if not ($notes_dir | path exists) {
        return $"Notes directory not found at ($notes_dir)"
    }
    let res = (^rg -i -n -C 1 -m ($limit | into string) --glob "*.typ" --glob "*.md" --glob "!template.typ" $query $notes_dir | complete)
    if ($res.exit_code == 0) and not ($res.stdout | is-empty) {
        $res.stdout | str replace -a $notes_dir "~"
    } else {
        $"No occurrences of '($query)' found across notes in ($notes_dir)."
    }
}
