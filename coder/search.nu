#!/usr/bin/env nu

# Search codebase for symbols, functions, or regex patterns using ripgrep
def main [
    query: string               # Search string or regex pattern
    --path (-p): string = "."   # Directory or file path to search
    --glob (-g): string = ""    # Optional file glob filter (e.g. '*.nu' or '*.py')
    --limit (-n): int = 20      # Maximum matching lines to return
] {
    mut args = ["-n" "--max-count" ($limit | into string)]
    if not ($glob | is-empty) {
        $args = ($args | append ["--glob" $glob])
    }
    $args = ($args | append [$query $path])

    let res = (^rg ...$args | complete)
    if ($res.exit_code == 0) and not ($res.stdout | is-empty) {
        $res.stdout
    } else if $res.exit_code == 1 {
        $"No matches found for '($query)' in ($path)."
    } else {
        $"Search error: ($res.stderr)"
    }
}
