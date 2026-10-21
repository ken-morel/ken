#!/usr/bin/env nu

# Get system statistics (CPU, RAM, disk, temperatures, load, uptime)
def main [] {
    let uptime = (^uptime -p | str trim)
    let load = (open /proc/loadavg | split row " " | slice 0..2 | str join ", ")
    let cpu_model = (try {
        ^lscpu | lines | where { |it| $it =~ "^Model name:" } | each { |l| $l | split row ":" | last | str trim } | first
    } catch { "Unknown CPU" })
    let gpu_model = (try {
        let pci = (^lspci | lines | where { |it| $it =~ "(?i)vga|3d|display" } | each { |l| $l | split row ": " | last } | str join ", ")
        if ($pci | is-empty) { "None detected" } else { $pci }
    } catch { "Unknown GPU" })
    let mem = (^free -h | lines | slice 0..2 | str join "\n")
    let disk = (^df -h / | lines | slice 0..2 | str join "\n")
    let temps = (try { ^sensors | lines | slice 0..12 | str join "\n" } catch { "Sensors unavailable" })

    $"System Statistics:
CPU: ($cpu_model)
GPU: ($gpu_model)
Uptime: ($uptime)
Load \(1, 5, 15m\): ($load)

Memory:
($mem)

Disk \(/):
($disk)

Temperatures:
($temps)"
}
