#!/usr/bin/env nu

# Calculate mathematical and unit conversion expressions using qalc
def main [
    expr: string # Mathematical or unit conversion expression to calculate
] {
    let res = (^qalc -t $expr | complete)
    if ($res.exit_code == 0) {
        $res.stdout | str trim
    } else {
        $"Calculation error: ($res.stderr)"
    }
}
