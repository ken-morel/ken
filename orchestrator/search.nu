#!/usr/bin/env nu

# Unified search across web, wikipedia, arxiv, github, packages, or weather with LFM filtering
def main [
    --query (-q): string         # The search query or topic
    --source (-s): string = "web" # Source: web (default), wiki, arxiv, gh, pkg, weather
    --limit (-n): int = 5        # Max results to return
] {
    if ("/dev/tty" | path exists) {
        $"\n[search] source: ($source) | query: ($query)\n" | save --append "/dev/tty"
    }

    let script_dir = ($env.FILE_PWD? | default ($env.HOME | path join "ken/orchestrator"))

    let raw_results = (match $source {
        "weather" => {
            let loc = ($query | str replace -a " " "+")
            http get $"https://wttr.in/($loc)?format=4&M"
        },
        "pkg" => {
            if (which yay | is-not-empty) {
                ^yay -Ss $query | complete | get stdout
            } else {
                ^pacman -Ss $query | complete | get stdout
            }
        },
        "gh" => {
            if (which gh | is-not-empty) {
                ^gh search repos $query --limit ($limit | into string) | complete | get stdout
            } else {
                let esc = ($query | url encode)
                let r = (try { http get $"https://api.github.com/search/repositories?q=($esc)&per_page=($limit)" } catch { {} })
                ($r.items? | default [] | each { |it| $"[($it.full_name)] ★($it.stargazers_count)\nURL: ($it.html_url)\n($it.description? | default '')\n" } | str join "\n")
            }
        },
        "wiki" => {
            let esc_q = ($query | url encode)
            let search_url = $"https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=1&srsearch=($esc_q)&format=json"
            let search_res = (try { http get $search_url } catch { null })
            let hit = ($search_res.query.search? | default [] | first)
            if ($hit == null) {
                $"No Wikipedia article found for '($query)'."
            } else {
                let title = $hit.title
                let pageid = ($hit.pageid | into string)
                let esc_title = ($title | url encode)
                let ext_url = $"https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=&titles=($esc_title)&exintro=&format=json"
                let ext_res = (try { http get $ext_url } catch { null })
                let extract = ($ext_res.query.pages | get $pageid | get extract? | default "")
                $"Wikipedia ($title):\n($extract)"
            }
        },
        "arxiv" => {
            let arxiv_script = ($script_dir | path join "search_arxiv.py")
            if ($arxiv_script | path exists) {
                ^python3 $arxiv_script $query ($limit | into string) | complete | get stdout
            } else {
                $"Error: search_arxiv.py not found in ($script_dir)"
            }
        },
        _ => {
            let web_script = ($script_dir | path join "search_web.py")
            if ($web_script | path exists) {
                ^python3 $web_script $query ($limit | into string) | complete | get stdout
            } else {
                $"Error: search_web.py not found in ($script_dir)"
            }
        }
    })

    # For web, wiki, and arxiv: run candidate results through LFM to filter noise and rank top matches
    if ($source in ["web", "wiki", "arxiv"]) and ($raw_results | str length) > 100 {
        if ("/dev/tty" | path exists) {
            $"[lfm] filtering candidate results for '($query)'...\n" | save --append "/dev/tty"
        }
        let lfm_prompt = $"Search results for: ($query)\n\nCandidates:\n($raw_results | str substring 0..6000)\n\nTask: Select and summarize the top ($limit) most relevant findings clearly. Include URLs."
        let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
        let ken_nu = ($ken_root | path join "ken.nu")
        let lfm_res = if ($ken_nu | path exists) {
            ^$ken_nu raw $lfm_prompt -m l --max-tokens 500 | complete
        } else {
            ^ken raw $lfm_prompt -m l --max-tokens 500 | complete
        }
        if $lfm_res.exit_code == 0 and not ($lfm_res.stdout | is-empty) {
            return $lfm_res.stdout
        }
    }

    if ("/dev/tty" | path exists) {
        $"[done] search ($source) -> ($raw_results | lines | length) lines\n" | save --append "/dev/tty"
    }
    $raw_results
}
