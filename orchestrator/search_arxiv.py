#!/usr/bin/env python3
import sys
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

def search_arxiv(query, limit=5):
    url = f"http://export.arxiv.org/api/query?search_query=all:{urllib.parse.quote_plus(query)}&max_results={limit}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            root = ET.fromstring(r.read())
        ns = {"atom": "http://www.w3.org/2005/Atom"}
        entries = root.findall("atom:entry", ns)
        if not entries:
            return f"No arXiv papers found for '{query}'."
        results = []
        for i, e in enumerate(entries, 1):
            title = " ".join(e.find("atom:title", ns).text.split())
            authors = ", ".join([a.find("atom:name", ns).text for a in e.findall("atom:author", ns) if a.find("atom:name", ns) is not None])
            link = e.find("atom:id", ns).text.strip()
            summary = " ".join(e.find("atom:summary", ns).text.split())[:350]
            results.append(f"[{i}] {title}\nAuthors: {authors}\nURL: {link}\nSummary: {summary}...")
        return "\n\n".join(results)
    except Exception as err:
        return f"Error querying arXiv: {err}"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: search_arxiv.py <query> [limit]")
        sys.exit(1)
    q = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(search_arxiv(q, n))
