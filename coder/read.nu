#!/usr/bin/env nu

# Read lines from a source code file with 1-based line numbering
def main [
    path: string              # Absolute or relative file path
    --start (-s): int = 1     # Starting line number (1-based)
    --lines (-n): int = 100   # Number of lines to read
] {
    if not ($path | path exists) {
        return $"Error: File '($path)' not found."
    }

    let all_lines = (open --raw $path | lines)
    let total = ($all_lines | length)
    let s_idx = (if $start > 1 { $start - 1 } else { 0 })
    let e_idx = ([$total, ($s_idx + $lines)] | math min)

    if $s_idx >= $total {
        return $"File has ($total) lines. Requested start ($start) is beyond end of file."
    }

    let slice = ($all_lines | slice $s_idx..($e_idx - 1))
    let formatted = ($slice | enumerate | each { |it|
        let line_num = ($s_idx + $it.index + 1)
        let num_str = ($line_num | fill -a right -w 4)
        $"($num_str) | ($it.item)"
    } | str join "\n")

    $"=== ($path) \(lines ($s_idx + 1)..($e_idx) of ($total)\) ===\n($formatted)"
}
