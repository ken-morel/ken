#!/usr/bin/env nu

# Get the current weather for a location
def main [
    --location (-l): string = "" # City and country (e.g. "Paris", "London")
] {
    let loc = ($location | str replace -a " " "+")
    http get $"https://wttr.in/($loc)?format=4&M"
}
