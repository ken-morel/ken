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

    if ("/dev/tty" | path exists) {
        let base = ($target_file | path basename)
        $"\n[notes/inspect] note: ($base) | question: ($question | str substring 0..40)...\n" | save --append "/dev/tty"
    }

    let note_content = (open --raw $target_file)

    let prompt = $"You are an academic extraction assistant for university student notes.
Note Document: ($target_file | path basename)
Content:
($note_content)

Student Question:
($question)

Instructions:
Extract the exact definitions, theorems, formulas, or answers from the note above.
Be precise and cite exact equations or sections.
If the information is not in this note, say 'Not mentioned in this note'. Output clean plain ASCII text."

    let payload = {
        model: "lfm"
        messages: [
            { role: "user", content: $prompt }
        ]
        temperature: 0.1
        max_tokens: 1024
        stream: false
    }

    let res = (try {
        http post --content-type "application/json" "http://127.0.0.1:6172/v1/chat/completions" ($payload | to json)
    } catch { |e|
        return $"LFM note inspection error: ($e.msg)"
    })

    try {
        $res.choices.0.message.content
    } catch {
        $"Error reading response: ($res)"
    }
}
