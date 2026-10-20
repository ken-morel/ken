#!/usr/bin/env nu

# Get the current date, day of week, and time
def main [] {
    date now | format date "%A, %B %d, %Y - %H:%M:%S %Z"
}
