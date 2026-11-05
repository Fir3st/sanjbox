#!/usr/bin/env python3
"""Build Sanďbox development status from its reviewed Markdown records (stdlib only)."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from html import escape
import json
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
from urllib.parse import quote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
ASSETS = Path(__file__).with_name("progress-site")
STATES = {"Neověřeno": "unverified", "Prošlo": "passed", "Neprošlo": "failed", "Nejasné": "unclear"}
WORK_STATES = {"⬜": "todo", "🟨": "active", "✅": "done", "⛔": "blocked"}
LABELS = {**{v: k for k, v in STATES.items()}, "todo": "Nezahájeno", "active": "Rozpracováno",
          "done": "Hotovo", "blocked": "Blokováno", "open": "Otevřený", "closed": "Uzavřený"}
PHASES = {"F0": "Rozhodnutí a základy", "F1": "Spiky a ověřování", "F2": "Jádro · MVP",
          "F3": "Coherence", "F4": "Docker, zařízení, git"}


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                          text=True, encoding="utf-8").stdout.strip()


def markdown_rows(text):
    """Yield table records with section and source line; ignore fenced examples."""
    section, group, headers, fence = "", "", None, None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line.startswith(("```", "~~~")):
            if fence is None:
                fence = line[:3]
            elif line.startswith(fence):
                fence = None
            headers = None
            continue
        if fence:
            continue
        if line.startswith("## "):
            section, group, headers = line[3:], "", None
        elif line.startswith("### "):
            group, headers = line[4:], None
        if not line.startswith("|"):
            headers = None
            continue
        cells = [cell.strip().replace(r"\|", "|") for cell in re.split(r"(?<!\\)\|", line.strip("|"))]
        if all(re.fullmatch(r":?-+:?", cell) for cell in cells):
            continue
        if headers is None:
            headers = cells
            continue
        if len(headers) != len(cells):
            raise ValueError(f"Řádek {number}: tabulka má {len(cells)} buněk místo {len(headers)}")
        yield section, group, number, dict(zip(headers, cells))


def plain(value):
    value = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", value)
    return value.replace("**", "").replace("`", "")


def verdict(value):
    name = plain(value).split(";", 1)[0].strip()
    if name not in STATES:
        raise ValueError(f"Neznámý verdikt: {value!r}")
    return STATES[name]


def require(row, *columns):
    missing = set(columns) - row.keys()
    if missing:
        raise ValueError(f"Chybí sloupce: {', '.join(sorted(missing))}")


def collect(coverage, implementation):
    data = {key: [] for key in ("packages", "requirements", "gates", "tests", "blockers")}
    definitions = {}
    for section, group, line, row in markdown_rows(implementation):
        if re.fullmatch(r"WP\d+\.[A-Z]?\d+", row.get("ID", "")):
            require(row, "Výstup", "Závislosti")
            if row["ID"] in definitions:
                raise ValueError(f"Duplicitní definice {row['ID']}")
            definitions[row["ID"]] = {"deliverable": row["Výstup"], "dependencies": row["Závislosti"],
                                       "definition_line": line, "stream": group}
    for section, group, line, row in markdown_rows(coverage):
        record = {"line": line}
        if section.startswith("4. "):
            require(row, "ID", "Balík", "Stav", "Vlastník", "Poznámka")
            identifier = row["ID"]
            if identifier not in definitions:
                raise ValueError(f"Balík {identifier} nemá definici v IMPLEMENTATION.md")
            state = plain(row["Stav"]).split(" ", 1)[0]
            if state not in WORK_STATES:
                raise ValueError(f"{identifier}: neznámý stav balíku {row['Stav']!r}")
            record.update(id=identifier, title=row["Balík"], owner=row["Vlastník"], note=row["Poznámka"],
                          state=WORK_STATES[state], phase="F" + identifier[2:identifier.index(".")],
                          **definitions[identifier])
            data["packages"].append(record)
        elif section.startswith("1. "):
            require(row, "Požadavek", "Rozhodující brány", "Stav")
            identifier, title = row["Požadavek"].split(" ", 1)
            record.update(id=identifier, title=title, dependencies=row["Rozhodující brány"],
                          state=verdict(row["Stav"]), note=row["Stav"])
            data["requirements"].append(record)
        elif section.startswith("2. ") and row.get("Brána") != "F0":
            require(row, "Brána", "Rozsah", "Závisí na", "Stav", "Verdikt")
            record.update(id=row["Brána"], title=row["Rozsah"], dependencies=row["Závisí na"],
                          state=verdict(row["Stav"]), evidence=row["Verdikt"])
            data["gates"].append(record)
        elif section.startswith("3. "):
            require(row, "ID", "Případ", "R", "Brána", "Stav", "Důkaz")
            if not re.fullmatch(r"[A-Z]+-\d{2,}", row["ID"]):
                raise ValueError(f"Neplatné ID případu: {row['ID']!r}")
            record.update(id=row["ID"], title=row["Případ"], requirements=row["R"], gates=row["Brána"],
                          state=verdict(row["Stav"]), evidence=row["Důkaz"], group=group)
            data["tests"].append(record)
        elif section.startswith("5. "):
            require(row, "Blokátor", "Požadavek", "Řeší", "Stav")
            if row["Stav"] not in ("Otevřený", "Uzavřený"):
                raise ValueError(f"Neznámý stav blokátoru: {row['Stav']!r}")
            record.update(id=f"B{len(data['blockers']) + 1:02}", title=row["Blokátor"],
                          requirements=row["Požadavek"], resolves=row["Řeší"],
                          state="open" if row["Stav"] == "Otevřený" else "closed")
            data["blockers"].append(record)
    for key, records in data.items():
        if not records:
            raise ValueError(f"COVERAGE.md: prázdná nebo chybějící sekce {key}")
        ids = [r["id"] for r in records]
        if len(ids) != len(set(ids)):
            raise ValueError(f"Duplicitní ID v sekci {key}")
    if set(definitions) != {p["id"] for p in data["packages"]}:
        raise ValueError("Balíky v COVERAGE.md a IMPLEMENTATION.md se neshodují")
    for record in data["tests"] + data["gates"]:
        if record["state"] == "passed" and not re.search(r"\[[^\]]+\]\([^)]+\)", record["evidence"]):
            raise ValueError(f"{record['id']}: Prošlo vyžaduje odkaz na důkaz")
        evidence_links(record["evidence"], "owner/repo", "HEAD")
    gate_states = {r["id"]: r["state"] for r in data["gates"]}
    for requirement in data["requirements"]:
        if requirement["state"] == "passed":
            dependencies = re.findall(r"\b(?:S\d+b?|F\d+)\b", requirement["dependencies"])
            if not dependencies or any(gate_states.get(g) != "passed" for g in dependencies):
                raise ValueError(f"{requirement['id']}: Prošlo vyžaduje prošlé rozhodující brány")
    data["summary"] = summarize(data)
    return data


def summarize(data):
    def count(records, success):
        states = dict(Counter(r["state"] for r in records))
        total, done = len(records), states.get(success, 0)
        return {"total": total, "done": done, "percent": round(100 * done / total, 2) if total else 0,
                "states": states}
    return {**{key: count(data[key], "done" if key == "packages" else "passed")
               for key in ("packages", "tests", "requirements")},
            "gates": count([g for g in data["gates"] if re.fullmatch(r"S\d+b?", g["id"])], "passed"),
            "blockers": count(data["blockers"], "closed"),
            "phases": {phase: count([p for p in data["packages"] if p["phase"] == phase], "done")
                       for phase in PHASES}}


def daily_commits(root, ref):
    if git(root, "rev-parse", "--is-shallow-repository") == "true":
        raise ValueError("Historie vyžaduje úplný checkout (fetch-depth: 0 / git fetch --unshallow)")
    days = {}
    for line in git(root, "log", "--first-parent", "--reverse", "--format=%H %ct", ref).splitlines():
        sha, timestamp = line.split()
        day = datetime.fromtimestamp(int(timestamp), timezone.utc).date().isoformat()
        days[day] = sha
    return sorted(days.items())


def history(root, ref):
    records = []
    for day, sha in daily_commits(root, ref):
        # Before the project had coverage there is no meaningful measurement.
        files = git(root, "ls-tree", "--name-only", sha, "docs/COVERAGE.md", "docs/IMPLEMENTATION.md").splitlines()
        if len(files) != 2:
            continue
        data = collect(git(root, "show", f"{sha}:docs/COVERAGE.md"),
                       git(root, "show", f"{sha}:docs/IMPLEMENTATION.md"))
        records.append({"date": day, "commit": sha, "summary": data["summary"]})
    return records


def source_url(repository, sha, path, line=None):
    suffix = f"#L{line}" if line else ""
    return f"https://github.com/{repository}/blob/{quote(sha, safe='')}/{quote(path, safe='/')}{suffix}"


def evidence_links(value, repository, sha):
    """Render only explicit HTTPS or repository-relative Markdown evidence links."""
    links = []
    for label, target in re.findall(r"\[([^\]]+)\]\(([^)]+)\)", value):
        url = urlsplit(target)
        if url.scheme == "https" and url.netloc:
            destination = target
        elif not url.scheme and not url.netloc and not url.path.startswith("/"):
            path = posixpath.normpath("docs/" + url.path)
            if path == ".." or path.startswith("../"):
                raise ValueError("Odkaz na důkaz vede mimo repozitář")
            destination = source_url(repository, sha, path)
            if url.fragment:
                destination += "#" + quote(url.fragment)
        else:
            raise ValueError(f"Nepodporovaný odkaz na důkaz: {target!r}")
        links.append(link(destination, plain(label) + " ↗"))
    return "<br>".join(links)


def link(url, label, css=""):
    return f'<a href="{escape(url, quote=True)}" class="{css}">{escape(str(label))}</a>'


# Preparation and laboratory packages behind each F1 gate (docs/IMPLEMENTATION.md, streams A–G).
GATE_PACKAGES = {
    "S0": ("WP1.A4", "WP1.A5"), "S1": ("WP1.A1", "WP1.A2", "WP1.A3"), "S2": ("WP1.F1", "WP1.F2"),
    "S3": ("WP1.C1", "WP1.C2", "WP1.C4"), "S3b": ("WP1.C3", "WP1.C4"),
    "S4": ("WP1.B1", "WP1.B2", "WP1.B3", "WP1.B4", "WP1.B5"),
    "S5": ("WP1.D1", "WP1.D2", "WP1.D3", "WP1.D4", "WP1.D5", "WP1.D6", "WP1.D7"),
    "S6": ("WP1.E1", "WP1.E2"), "S7": ("WP1.G1", "WP1.G2", "WP1.G3"), "S8": ("WP1.A6", "WP1.A7"),
}


def czech_date(day):
    value = datetime.fromisoformat(day)
    return f"{value.day}. {value.month}. {value.year}"


def changes(root, ref, limit=12):
    """Most recent pull requests merged into the first-parent history, newest first."""
    log = git(root, "log", "--first-parent", "--merges", f"-{limit}", "--format=%cs%x1f%s%x1f%b%x1e", ref)
    entries = []
    for record in filter(None, (r.strip() for r in log.split("\x1e"))):
        day, subject, body = (record.split("\x1f") + [""])[:3]
        number = re.match(r"Merge pull request #(\d+) ", subject)
        if number:
            title = next((line.strip() for line in body.splitlines() if line.strip()), subject)
            entries.append({"date": day, "number": int(number[1]), "title": title})
    return entries


def gate_order(gate):
    number, suffix = re.fullmatch(r"S(\d+)(b?)", gate["id"]).groups()
    return int(number), suffix


def render(data, repository, sha, dirty, merged=(), updated=""):
    """The single status page: overall state, gates as components, phases and recent changes."""
    def source(record):
        return escape(source_url(repository, sha, "docs/COVERAGE.md", record["line"]), quote=True)

    summary = data["summary"]
    packages = {p["id"]: p for p in data["packages"]}
    gates = sorted((g for g in data["gates"] if re.fullmatch(r"S\d+b?", g["id"])), key=gate_order)
    if {g["id"] for g in gates} != set(GATE_PACKAGES) or not set().union(*GATE_PACKAGES.values()) <= packages.keys():
        raise ValueError("GATE_PACKAGES neodpovídá branám a balíkům v COVERAGE.md")

    passed, total = summary["gates"]["done"], summary["gates"]["total"]
    failed = sum(g["state"] == "failed" for g in gates)
    if passed == total:
        banner = ("done", "Všechny ověřovací brány prošly", "Izolace je doložená protokoly v rozsahu bran S0–S8.")
    elif failed:
        banner = ("failed", f"Neprošlo {failed} z {total} ověřovacích bran",
                  "Izolace v rozsahu neprošlých bran neplatí. Nepoužívej se skutečnými projekty, účty ani tajemstvími.")
    elif passed:
        banner = ("active", f"Prošlo {passed} z {total} ověřovacích bran",
                  "Izolace platí jen v rozsahu prošlých bran.")
    else:
        banner = ("active", "Ve vývoji, izolace zatím neověřená",
                  f"Žádná z {total} ověřovacích bran zatím neprošla. Nepoužívej se skutečnými projekty, účty ani tajemstvími.")

    rows = ""
    for g in gates:
        title = plain(g["title"])
        scope = re.search(r"\s*\((mimo MVP)[^)]*\)", title)
        tag = f'<span class="tag">{scope[1]}</span>' if scope else ""
        title = title.replace(scope[0], "") if scope else title
        work = [packages[i] for i in GATE_PACKAGES[g["id"]]]
        segments = ""
        for p in work:
            label = escape(f'{p["id"]} {plain(p["title"])}: {LABELS[p["state"]].lower()}', quote=True)
            segments += f'<a class="{p["state"]}" href="{source(p)}" title="{label}" aria-label="{label}"></a>'
        done = sum(p["state"] == "done" for p in work)
        active = sum(p["state"] == "active" for p in work)
        rows += (f'<li id="gate-{g["id"]}"><div class="row"><span class="id">{g["id"]}</span>'
                 f'<a class="name" href="{source(g)}">{escape(title)}</a>{tag}'
                 f'<span class="state {g["state"]}"><span class="dot" aria-hidden="true"></span>{LABELS[g["state"]]}</span></div>'
                 f'<div class="bar">{segments}</div>'
                 f'<div class="meta">Příprava {done}/{len(work)} hotovo{f" · {active} rozpracováno" if active else ""}</div></li>')

    started = [phase for phase in PHASES if any(p["phase"] == phase and p["state"] != "todo" for p in data["packages"])]
    current = started[-1] if started else next(iter(PHASES))
    phases = ""
    for phase, title in PHASES.items():
        count = summary["phases"][phase]
        css = ' class="current" aria-current="step"' if phase == current else ""
        phases += (f'<li{css}><span class="id">{phase}</span><span class="name">{escape(title)}</span>'
                   f'<span class="count"><b>{count["done"]}</b> / {count["total"]}</span>'
                   f'<span class="track"><span style="width:{count["percent"]:g}%"></span></span></li>')

    days = {}
    for entry in merged:
        url = f"https://github.com/{repository}/pull/{entry['number']}"
        days.setdefault(entry["date"], []).append(f'<li><span>#{entry["number"]}</span>{link(url, entry["title"])}</li>')
    timeline = "".join(f'<div class="day"><h3>{czech_date(day)}</h3><ul>{"".join(items)}</ul></div>'
                       for day, items in days.items()) or '<div class="day"><h3>Zatím žádné sloučené PR</h3></div>'

    snapshot = ("lokální náhled s necommitovanými změnami" if dirty else
                f'commit {link(f"https://github.com/{repository}/commit/{sha}", sha[:7])}')
    values = {
        "repository": escape(f"https://github.com/{repository}", quote=True),
        "plan": escape(source_url(repository, sha, "PLAN.md"), quote=True),
        "coverage": escape(source_url(repository, sha, "docs/COVERAGE.md"), quote=True),
        "method": escape(source_url(repository, sha, "docs/PROGRESS.md"), quote=True),
        "banner_state": banner[0], "banner_title": escape(banner[1]), "banner_text": escape(banner[2]),
        "updated": escape(czech_date(updated)) if updated else "", "snapshot": snapshot,
        "gates": rows, "phases": phases, "changes": timeline,
    }
    template = (ASSETS / "page.html").read_text(encoding="utf-8")
    return {"index.html": re.sub(r"\{\{(\w+)\}\}", lambda m: values[m[1]], template)}


# Former subpages stay reachable for links shared before the single-page status site.
REDIRECTS = {"progress.html": "index.html", "history.html": "index.html"}


def redirect(target):
    return (f'<!doctype html>\n<meta charset="utf-8">\n<meta http-equiv="refresh" content="0; url={target}">\n'
            f'<link rel="canonical" href="{target}">\n<title>Sanďbox · stav vývoje</title>\n'
            f'<p><a href="{target}">Stav vývoje je na úvodní stránce.</a></p>\n')


def build(root, out, repository, ref="HEAD"):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Repozitář musí mít tvar owner/name")
    sha = git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")
    # Current source is the working tree; history may explicitly follow another local ref.
    head = git(root, "rev-parse", "HEAD")
    dirty = bool(git(root, "status", "--porcelain"))
    data = collect((root / "docs/COVERAGE.md").read_text(encoding="utf-8"),
                   (root / "docs/IMPLEMENTATION.md").read_text(encoding="utf-8"))
    records = history(root, sha)
    data.update(schema_version=1, commit=head, working_tree=dirty, repository=repository,
                history_ref=sha, counting_rules="docs/PROGRESS.md")
    pages = render(data, repository, head, dirty, changes(root, sha),
                   git(root, "log", "-1", "--format=%cs", head))
    pages.update({name: redirect(target) for name, target in REDIRECTS.items()})
    out.mkdir(parents=True, exist_ok=True)
    for name, html in pages.items():
        (out / name).write_text(html, encoding="utf-8")
    for name, payload in (("progress.json", data), ("history.json", {"schema_version": 1, "ref": sha, "days": records})):
        (out / name).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for name in ("style.css", "app.js"):
        shutil.copyfile(ASSETS / name, out / name)
    (out / ".nojekyll").touch()
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/progress")
    parser.add_argument("--repository", default="Fir3st/sanjbox")
    parser.add_argument("--history-ref", default="HEAD", help="Local Git ref; full first-parent history required")
    args = parser.parse_args()
    try:
        data = build(ROOT, args.out, args.repository, args.history_ref)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Progress build failed: {error}", file=sys.stderr)
        return 1
    print(f"Built {args.out}: {data['summary']['packages']['done']}/{data['summary']['packages']['total']} packages, "
          f"{data['summary']['tests']['done']}/{data['summary']['tests']['total']} acceptance cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
