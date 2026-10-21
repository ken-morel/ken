#!/usr/bin/env nu

# Read the contents of a text file safely
def main [
    path: string              # Path to the file to read
    --lines (-n): int = 500   # Maximum number of lines to read (default 500)
    --offset: int = 1         # Starting line offset (1-indexed)
] {
    let target = ($path | path expand)

    if not ($target | path exists) {
        return $"Error: file '($path)' not found."
    }

    try {
        let all_lines = (open --raw $target | lines)
        let total = ($all_lines | length)
        let raw_start = ($offset - 1)
        let start_idx = if $raw_start < 0 { 0 } else { $raw_start }
        let end_idx = ($start_idx + $lines)
        let selected = ($all_lines | slice $start_idx..$end_idx)
        let max_shown = if $end_idx > $total { $total } else { $end_idx }
        let header = $"File: ($target) \(lines ($offset)..($max_shown) of ($total)\)\n"
        $header + ($selected | str join "\n")
    } catch { |e|
        $"Error reading file '($target)': ($e.msg)"
    }
}
