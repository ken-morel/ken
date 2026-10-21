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
    let note_lines = ($note_content | lines | length)
    let note_sz = ($note_content | str length | into filesize)

    if ("/dev/tty" | path exists) {
        let base = ($target_file | path basename)
        $"\e[2m[inspecting]\e[0m ($base) \(($note_lines) lines, ($note_sz)\) | query: ($question)\n" | save --append "/dev/tty"
    }

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

    let payload = {
        model: "lfm"
        messages: [
            { role: "user", content: $prompt }
        ]
        temperature: 0.1
        max_tokens: 2048
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
