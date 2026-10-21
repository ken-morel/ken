#!/usr/bin/env nu

# List directory contents with details
def main [
    path: string = "." # Directory path to list
    --all (-a)         # Include hidden dotfiles
] {
    let target = ($path | path expand)

    if not ($target | path exists) {
        return $"Error: path '($path)' does not exist."
    }

    let items = if $all {
        ls -a $target
    } else {
        ls $target
    }

    if ($items | is-empty) {
        return $"Directory '($target)' is empty."
    }

    $items | select name type size modified | to text
}
