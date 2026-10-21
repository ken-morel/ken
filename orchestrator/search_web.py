#!/usr/bin/env python3
import sys
import re
import html
import urllib.request
import urllib.parse

def search_ddg_lite(query, limit=5):
    url = "https://lite.duckduckgo.com/lite/"
    data = urllib.parse.urlencode({"q": query}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="ignore")
    except Exception as e:
        return f"Error connecting to DuckDuckGo: {e}"

    matches = re.findall(
        r'<a[^>]+href=["\']([^"\']+)["\'][^>]+class=["\']result-link["\'][^>]*>(.*?)</a>',
        body,
        re.DOTALL
    )
    snippets = re.findall(
        r'class=["\']result-snippet["\'][^>]*>(.*?)</td>',
        body,
        re.DOTALL
    )

    def clean(t):
        return html.unescape(re.sub(r'<[^>]+>', '', t)).strip()

    results = []
    max_count = min(limit, len(matches))
    for i in range(max_count):
        raw_url, title_raw = matches[i]
        link = raw_url
        if "duckduckgo.com/l/" in raw_url:
            parsed_q = urllib.parse.parse_qs(urllib.parse.urlparse(raw_url).query)
            link = parsed_q.get("uddg", [raw_url])[0]
        title = clean(title_raw)
        snip = clean(snippets[i]) if i < len(snippets) else ""
        results.append(f"[{i+1}] {title}\nURL: {link}\n{snip}")

    if not results:
        return f"No results found for '{query}'."
    return "\n\n".join(results)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: search_web.py <query> [limit]")
        sys.exit(1)
    q = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(search_ddg_lite(q, n))
