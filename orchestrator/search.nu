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
            let py_code = "
import sys, urllib.request, urllib.parse, xml.etree.ElementTree as ET
q = sys.argv[1]
url = f'http://export.arxiv.org/api/query?search_query=all:{urllib.parse.quote_plus(q)}&max_results=8'
try:
    with urllib.request.urlopen(url, timeout=10) as r: root = ET.fromstring(r.read())
    ns = {'atom': 'http://www.w3.org/2005/Atom'}
    entries = root.findall('atom:entry', ns)
    for i, e in enumerate(entries, 1):
        title = ' '.join(e.find('atom:title', ns).text.split())
        authors = ', '.join([a.find('atom:name', ns).text for a in e.findall('atom:author', ns) if a.find('atom:name', ns) is not None])
        link = e.find('atom:id', ns).text.strip()
        summary = ' '.join(e.find('atom:summary', ns).text.split())[:350]
        print(f'[{i}] {title}\nAuthors: {authors}\nURL: {link}\nSummary: {summary}\n')
except Exception as err:
    print(f'Error: {err}')
"
            python3 -c $py_code $query
        },
        _ => {
            # Web search via DDG Lite (fetches 10 results)
            let py_code = "
import sys, re, html, urllib.request, urllib.parse
query = sys.argv[1]
url = 'https://lite.duckduckgo.com/lite/'
data = urllib.parse.urlencode({'q': query}).encode('utf-8')
req = urllib.request.Request(url, data=data, headers={'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp: body = resp.read().decode('utf-8', errors='ignore')
    matches = re.findall(r'<a[^>]+href=[\'\"]([^\'\"]+)[\'\"][^>]+class=[\'\"]result-link[\'\"][^>]*>(.*?)</a>', body, re.DOTALL)
    snippets = re.findall(r'class=[\'\"]result-snippet[\'\"][^>]*>(.*?)</td>', body, re.DOTALL)
    def clean(t): return html.unescape(re.sub(r'<[^>]+>', '', t)).strip()
    results = []
    for i in range(min(10, len(matches))):
        raw_url, title_raw = matches[i]
        link = urllib.parse.parse_qs(urllib.parse.urlparse(raw_url).query).get('uddg', [raw_url])[0] if 'duckduckgo.com/l/' in raw_url else raw_url
        title, snip = clean(title_raw), clean(snippets[i]) if i < len(snippets) else ''
        results.append(f'[{i+1}] {title}\nURL: {link}\n{snip}')
    print('\n\n'.join(results) if results else 'No results found.')
except Exception as e:
    print(f'Error: {e}')
"
            python3 -c $py_code $query
        }
    })

    # For web, wiki, and arxiv: run candidate results through LFM to filter noise and rank top matches
    if ($source in ["web", "wiki", "arxiv"]) and ($raw_results | str length) > 100 {
        if ("/dev/tty" | path exists) {
            $"[lfm] filtering candidate results for '($query)'...\n" | save --append "/dev/tty"
        }
        let lfm_prompt = $"Search results for: ($query)\n\nCandidates:\n($raw_results | str substring 0..6000)\n\nTask: Select and summarize the top ($limit) most relevant findings clearly. Include URLs."
        let lfm_body = {
            model: "lfm",
            messages: [{ role: "user", content: $lfm_prompt }],
            max_tokens: 500
        }
        let lfm_res = (try { http post --content-type application/json http://127.0.0.1:6172/v1/chat/completions $lfm_body } catch { null })
        if ($lfm_res != null) {
            let out = $lfm_res.choices.0.message.content
            if ("/dev/tty" | path exists) {
                $"[done] search ($source) -> ($out | lines | length) lines\n" | save --append "/dev/tty"
            }
            return $out
        }
    }

    if ("/dev/tty" | path exists) {
        $"[done] search ($source) -> ($raw_results | lines | length) lines\n" | save --append "/dev/tty"
    }
    $raw_results
}
