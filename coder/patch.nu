#!/usr/bin/env nu

# Safely apply a surgical text patch to a file with automatic syntax verification and rollback
def main [
    path: string                # Target file path to patch
    target: string              # Exact verbatim text block to replace
    replacement: string         # New replacement text block
    --verify (-v): string = ""  # Optional verification command (e.g. 'nu --ide-check 10 file.nu' or 'python3 -m py_compile file.py')
] {
    if not ($path | path exists) {
        return $"Error: Target file '($path)' not found."
    }

    let original = (open --raw $path)
    if not ($original | str contains $target) {
        return $"Error: Target string not found in '($path)'. Ensure whitespace and lines match exactly."
    }

    let count = ($original | split row $target | length) - 1
    if $count > 1 {
        return $"Error: Target string appears ($count) times in '($path)'. Provide more surrounding context to match a unique region."
    }

    # Backup original content
    let backup = $original

    # Apply replacement
    let updated = ($original | str replace $target $replacement)
    $updated | save -f $path

    # If verification command specified, run it
    if not ($verify | is-empty) {
        let check_res = (^bash -c $verify | complete)
        if $check_res.exit_code != 0 {
            # Rollback immediately
            $backup | save -f $path
            return $"Verification FAILED \(changes rolled back\):\nCommand: ($verify)\nExit: ($check_res.exit_code)\nStderr: ($check_res.stderr)\nStdout: ($check_res.stdout)"
        }
        return $"Patch applied and verified successfully!\nVerification command passed: ($verify)"
    }

    $"Patch applied successfully to '($path)'."
}
