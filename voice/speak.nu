#!/usr/bin/env nu

# Read text aloud to the user using text-to-speech
def main [
    text: string                # Text message to speak aloud
    --speed (-s): string = "1.0" # Speech speed multiplier (e.g. 1.0, 1.2)
] {
    if ("/dev/tty" | path exists) {
        $"\n[voice/speak] speaking: ($text | str substring 0..40)...\n" | save --append "/dev/tty"
    }

    let script_dir = ($env.FILE_PWD? | default ($env.PWD | path join "voice"))
    let runner = ($script_dir | path join "readaloud.k")
    
    let res = (^$runner -s $speed $text | complete)
    if ($res.exit_code == 0) {
        $"Successfully read aloud: \"($text)\""
    } else {
        $"Failed to read aloud: ($res.stderr)"
    }
}
