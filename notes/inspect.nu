#!/usr/bin/env nu

# Inspect a note file and extract targeted answers or definitions using fast LFM
def main [
    note: string     # Note filename or subject (e.g. analysis, operating-systems, stat-n-prob)
    question: string # Specific question, theorem, formula, or concept to extract
] {
    let notes_dir = ($env.HOME | path join "Documents" "notes")
    
    # Resolve note file
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
                return $"Note matching '($note)' not found in ($notes_dir). Use 'list' to see available notes."
            }
        }
    }

    let note_content = (open --raw $target_file)

    let prompt = $"You are an academic extraction assistant for university student notes.
Note Document: ($target_file | path basename)
Content:
($note_content)

Student Question:
($question)

Instructions:
Extract all content, definitions, theorems, formulas, code, diagrams, and explanations regarding '($question)' from the note above.
Be thorough and mathematically precise. Quote relevant formulas, definitions, and rules verbatim without summarizing away essential technical details.
If the information is not in this note, say 'Not mentioned in this note'. Output clean plain ASCII text."

    let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
    let ken_nu = ($ken_root | path join "ken.nu")
    let res = if ($ken_nu | path exists) {
        ^$ken_nu raw $prompt -m l --max-tokens 2048 | complete
    } else {
        ^ken raw $prompt -m l --max-tokens 2048 | complete
    }

    if $res.exit_code == 0 {
        $res.stdout
    } else {
        $"LFM note inspection error: ($res.stderr)\n($res.stdout)"
    }
}
