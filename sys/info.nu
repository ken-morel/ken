#!/usr/bin/env nu

# Get system statistics (CPU, RAM, disk, temperatures, load, uptime)
def main [] {
    if ("/dev/tty" | path exists) {
        $"\n[sys/info] gathering system metrics\n" | save --append "/dev/tty"
    }

    let uptime = (^uptime -p | str trim)
    let load = (open /proc/loadavg | split row " " | slice 0..2 | str join ", ")
    let mem = (^free -h | lines | slice 0..2 | str join "\n")
    let disk = (^df -h / | lines | slice 0..2 | str join "\n")
    let temps = (try { ^sensors | lines | slice 0..12 | str join "\n" } catch { "Sensors unavailable" })

    $"System Statistics:
Uptime: ($uptime)
Load \(1, 5, 15m\): ($load)

Memory:
($mem)

Disk \(/):
($disk)

Temperatures:
($temps)"
}
