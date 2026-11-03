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


def badge(state):
    return f'<span class="status {state}"><span aria-hidden="true">●</span> {LABELS[state]}</span>'


def table(headers, rows, caption):
    return (f'<div class="table-wrap"><table><caption class="sr-only">{escape(caption)}</caption><thead><tr>'
            + "".join(f'<th scope="col">{escape(h)}</th>' for h in headers)
            + '</tr></thead><tbody>' + "".join(rows) + '</tbody></table></div>')


def chart(records, key, title):
    width, height, left, top, bottom = 700, 230, 44, 20, 190
    maximum = max([r["summary"][key]["total"] for r in records] + [1])
    parts = [f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}" class="chart">']
    for fraction in (0, .5, 1):
        y = bottom - fraction * (bottom - top)
        parts.append(f'<path d="M{left} {y}H680" class="gridline"/><text x="8" y="{y + 4}">{maximum * fraction:g}</text>')
    for field, css in (("total", "total-line"), ("done", "done-line")):
        points = []
        dates = [datetime.fromisoformat(r["date"]).toordinal() for r in records]
        span = max(dates) - min(dates) if dates else 0
        for index, record in enumerate(records):
            x = left + (dates[index] - min(dates)) * 636 / span if span else 362
            value = record["summary"][key][field]
            y = bottom - value / maximum * (bottom - top)
            points.append(f"{x:.2f},{y:.2f}")
            label = f"{record['date']}: {value} ({'celkem' if field == 'total' else 'hotovo / prošlo'})"
            parts.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="4" class="{css}"><title>{escape(label)}</title></circle>')
        if points:
            parts.append(f'<polyline points="{" ".join(points)}" class="{css}"/>')
    if records:
        parts.append(f'<text x="44" y="220">{records[0]["date"]}</text>')
        if len(records) > 1:
            parts.append(f'<text x="680" y="220" text-anchor="end">{records[-1]["date"]}</text>')
    parts.append('</svg>')
    return "".join(parts)


def overview_svg(data):
    """A portable, self-contained progress map suitable for README embedding."""
    colors = {"done": "#7de2b8", "active": "#eac078", "blocked": "#ed8989", "todo": "#263c36"}
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 250" role="img" aria-labelledby="title desc">',
             '<title id="title">Sanďbox — stav vývoje</title>',
             '<desc id="desc">Každé políčko je jeden pracovní balík. Hotový balík není důkaz izolace.</desc>',
             '<rect width="1000" height="250" rx="12" fill="#111b18"/>',
             '<g font-family="system-ui,sans-serif" fill="#e6eee9">',
             '<text x="24" y="34" font-size="20">Sanďbox · stav vývoje</text>']
    for index, (phase, title) in enumerate(PHASES.items()):
        x = 24 + index * 195
        summary = data["summary"]["phases"][phase]
        parts.append(f'<text x="{x}" y="70" font-size="13">{phase} · {summary["done"]}/{summary["total"]} hotovo</text>')
        for i, p in enumerate(p for p in data["packages"] if p["phase"] == phase):
            parts.append(f'<rect x="{x + i % 6 * 28}" y="{84 + i // 6 * 20}" width="23" height="15" rx="2" fill="{colors[p["state"]]}"><title>{escape(p["id"] + ": " + p["title"] + " — " + LABELS[p["state"]])}</title></rect>')
    packages, gates, tests = (data["summary"][k] for k in ("packages", "gates", "tests"))
    parts.append(f'<text x="24" y="215" font-size="14">Balíky {packages["done"]}/{packages["total"]} · Brány F1 {gates["done"]}/{gates["total"]} · Ověřené případy {tests["done"]}/{tests["total"]}</text>')
    parts.append('<text x="24" y="237" font-size="11" fill="#a5b8ae">Zelená: hotovo · Žlutá: rozpracováno · Šedá: nezahájeno · Červená: blokováno. Balíky mají různou pracnost.</text></g></svg>')
    return "".join(parts)


def render(data, records, repository, sha, dirty):
    def source(record, path="docs/COVERAGE.md", label=None):
        return link(source_url(repository, sha, path, record["line"]), label or record["id"], "mono")

    summary = data["summary"]
    cards = ""
    for key, title, note in (("packages", "Hotové balíky", "dokončené části implementace"),
                             ("gates", "Brány F1", "s uzavřeným ověřením"),
                             ("tests", "Ověřené případy", "doložené laboratorním důkazem"),
                             ("requirements", "Požadavky", "splněné podle kontraktu")):
        item = summary[key]
        cards += f'<article class="metric"><p>{title}</p><div><strong>{item["done"]:02}</strong><span>/ {item["total"]}</span></div><progress value="{item["done"]}" max="{item["total"]}">{item["percent"]}%</progress><small>{note}</small></article>'
    maps = ""
    phases = ""
    for phase, title in PHASES.items():
        items = [p for p in data["packages"] if p["phase"] == phase]
        count = summary["phases"][phase]
        tiles = "".join(f'<a class="tile {p["state"]}" href="#package-{p["id"]}" aria-label="{escape(p["id"] + ": " + plain(p["title"]) + " — " + LABELS[p["state"]])}" title="{escape(p["id"] + ": " + plain(p["title"]) + " — " + LABELS[p["state"]])}">{escape(p["id"].replace("WP", ""))}</a>' for p in items)
        maps += f'<div class="map-group"><div class="map-label"><b>{phase}</b><span>{count["done"]}/{count["total"]}</span></div><div class="tiles">{tiles}</div></div>'
        phases += f'<article class="phase"><span class="mono">{phase}</span><h3>{title}</h3><p>{count["done"]} z {count["total"]} balíků</p><progress value="{count["done"]}" max="{count["total"]}">{count["percent"]}%</progress></article>'
    test_maps = ""
    for prefix in dict.fromkeys(t["id"].split("-")[0] for t in data["tests"]):
        items = [t for t in data["tests"] if t["id"].startswith(prefix + "-")]
        tiles = "".join(f'<a class="test-tile {t["state"]}" href="#test-{t["id"]}" aria-label="{t["id"]}: {LABELS[t["state"]]}" title="{escape(t["id"] + ": " + plain(t["title"]))}"></a>' for t in items)
        test_maps += f'<div class="test-group"><span class="mono">{prefix}</span><div>{tiles}</div><span>{sum(t["state"] == "passed" for t in items)}/{len(items)}</span></div>'
    package_rows = []
    for p in data["packages"]:
        package_rows.append(f'<tr id="package-{p["id"]}" data-phase="{p["phase"]}" data-state="{p["state"]}"><td>{source(p)}<small>{p["phase"]}</small></td><td><strong>{escape(plain(p["title"]))}</strong><details><summary>Výstup a návaznosti</summary><p>{escape(plain(p["deliverable"]))}</p><p>Závislosti: {escape(plain(p["dependencies"]))}</p></details><small>{escape(plain(p["note"]))}</small></td><td>{badge(p["state"])}</td><td>{escape(plain(p["owner"])) or "—"}</td></tr>')
    gate_rows = [f'<tr><td>{source(g)}</td><td>{escape(plain(g["title"]))}</td><td>{escape(plain(g["dependencies"]))}</td><td>{badge(g["state"])}</td><td>{evidence_links(g["evidence"], repository, sha) or source(g, label="Záznam ↗")}</td></tr>' for g in data["gates"]]
    requirement_rows = [f'<tr><td>{source(r)}</td><td>{escape(plain(r["title"]))}<small>{escape(plain(r["note"]))}</small></td><td>{escape(r["dependencies"])}</td><td>{badge(r["state"])}</td></tr>' for r in data["requirements"]]
    test_rows = [f'<tr id="test-{t["id"]}" data-state="{t["state"]}"><td>{source(t)}</td><td>{escape(plain(t["title"]))}</td><td>{escape(t["gates"])}</td><td>{badge(t["state"])}</td><td>{evidence_links(t["evidence"], repository, sha) or source(t, label="Záznam ↗")}</td></tr>' for t in data["tests"]]
    blockers = "".join(f'<article class="blocker"><span class="mono">{b["id"]}</span><div><h3>{escape(plain(b["title"]))}</h3><p>{escape(b["requirements"])} · Řeší: {escape(plain(b["resolves"]))}</p></div>{badge(b["state"])}{source(b, label="Zdroj ↗")}</article>' for b in data["blockers"])
    scope = link(source_url(repository, sha, "docs/DECISIONS.md"), "Rozsah MVP a rozhodnutí ↗")
    overview = f'''<section class="hero"><div><p class="eyebrow">DEVELOPMENT STATUS</p><h1>Od návrhu<br>k ověřené izolaci<span>.</span></h1><p class="intro">Nativní oblasti pro AI agenty na macOS.<br>Průběžný stav implementace, ověřování a otevřených překážek.</p></div><aside class="project-state"><span class="status active">● Vývoj a ověřování</span><p>Žádná izolace zatím není prokázaná.</p><small>MVP: CLI a jedno okno s plochou oblasti.<br>Coherence a Docker následují ve F3 a F4.</small>{scope}</aside></section>
<div class="metrics">{cards}</div>
<section id="map" class="section"><div class="section-heading"><div><p class="eyebrow">01 / MAPA PROGRESU</p><h2>Co už existuje. Co ještě zbývá.</h2></div>{link('progress.svg', 'Stáhnout SVG ↗', 'subtle')}</div><div class="map-panels"><article class="panel"><div class="panel-heading"><h3>Implementace</h3><span>{summary['packages']['percent']:g}% balíků</span></div><div class="package-map">{maps}</div><div class="legend"><span class="done">● Hotovo</span><span class="active">● Rozpracováno</span><span class="todo">● Nezahájeno</span><span class="blocked">● Blokováno</span></div><p class="fine">Jedno políčko = jeden balík. Balíky mají různou pracnost; podíl nevyjadřuje procento hotového produktu.</p></article><article class="panel"><div class="panel-heading"><h3>Ověřování</h3><span>{summary['tests']['done']} / {summary['tests']['total']} prošlo</span></div>{test_maps}<div class="legend"><span class="passed">● Prošlo</span><span class="unverified">● Neověřeno</span><span class="failed">● Neprošlo</span><span class="unclear">● Nejasné</span></div><p class="fine">Jedno políčko = jeden akceptační případ. Kliknutím přejdete na jeho záznam.</p></article></div></section>
<section id="roadmap" class="section"><div class="section-heading"><div><p class="eyebrow">02 / ROADMAPA</p><h2>Pět fází, jasné návaznosti.</h2></div>{link(source_url(repository, sha, 'docs/IMPLEMENTATION.md'), 'Plán implementace ↗', 'subtle')}</div><div class="phases">{phases}</div></section>
<section id="packages" class="section filter-section"><div class="section-heading"><div><p class="eyebrow">03 / IMPLEMENTACE</p><h2>Pracovní balíky</h2></div><span class="filter-count" aria-live="polite">{len(package_rows)} balíků</span></div><div class="filters" hidden><label>Hledat<input type="search" placeholder="ID, název nebo vlastník…"></label><label>Fáze<select data-filter="phase"><option value="">Všechny fáze</option>{''.join(f'<option>{p}</option>' for p in PHASES)}</select></label><label>Stav<select data-filter="state"><option value="">Všechny stavy</option>{''.join(f'<option value="{s}">{LABELS[s]}</option>' for s in WORK_STATES.values())}</select></label></div>{table(['Balík', 'Název a výstup', 'Stav', 'Vlastník'], package_rows, 'Pracovní balíky')}<p class="empty" hidden>Žádný balík neodpovídá filtrům.</p></section>
<section id="gates" class="section"><div class="section-heading"><div><p class="eyebrow">04 / DŮKAZY</p><h2>Brány a požadavky</h2></div><span class="subtle">Hotový balík ≠ prošlá brána</span></div>{table(['Brána', 'Rozsah', 'Závisí na', 'Verdikt', 'Důkaz / záznam'], gate_rows, 'Ověřovací brány')}<details class="requirements"><summary>Požadavky R1–R8 a jejich rozhodující brány</summary>{table(['ID', 'Požadavek', 'Brány', 'Stav'], requirement_rows, 'Požadavky produktu')}</details></section>
<section id="blockers" class="section"><div class="section-heading"><div><p class="eyebrow">05 / OTEVŘENÉ OTÁZKY</p><h2>Blokátory</h2></div><span class="subtle">{summary['blockers']['states'].get('open', 0)} otevřených</span></div><div class="blockers">{blockers}</div></section>
<section id="tests" class="section filter-section"><div class="section-heading"><div><p class="eyebrow">06 / AKCEPTACE</p><h2>Testové případy</h2></div><span class="filter-count" aria-live="polite">{len(test_rows)} případů</span></div><div class="filters" hidden><label>Hledat<input type="search" placeholder="ID nebo popis případu…"></label><label>Verdikt<select data-filter="state"><option value="">Všechny verdikty</option>{''.join(f'<option value="{s}">{LABELS[s]}</option>' for s in STATES.values())}</select></label></div>{table(['ID', 'Případ', 'Brána', 'Verdikt', 'Důkaz / záznam'], test_rows, 'Akceptační případy')}<p class="empty" hidden>Žádný případ neodpovídá filtrům.</p></section>'''
    history_rows = []
    for r in reversed(records):
        cells = [escape(r["date"]), link(f'https://github.com/{repository}/commit/{r["commit"]}', r["commit"][:7], 'mono')]
        for key in ("packages", "gates", "tests", "requirements"):
            item = r["summary"][key]
            cells.append(f'{item["done"]} / {item["total"]}')
        history_rows.append('<tr>' + ''.join(f'<td>{cell}</td>' for cell in cells) + '</tr>')
    charts = ''.join(f'<article class="panel"><div class="panel-heading"><h2>{title}</h2></div>{chart(records, key, title)}<div class="legend"><span class="done">━ Hotovo / prošlo</span><span>┄ Celkem v evidenci</span></div></article>' for key, title in (("packages", "Pracovní balíky"), ("tests", "Akceptační případy")))
    history_body = f'''<section class="history-hero"><p class="eyebrow">PROGRESS HISTORY</p><h1>Postup v čase<span>.</span></h1><p class="intro">Hotové balíky a ověřené případy vůči celému evidovanému rozsahu.</p></section><div class="map-panels">{charts}</div><p class="fine">Jeden bod za den UTC: poslední commit dne na first-parent historii zvoleného refu. Počítáno stejnými pravidly jako aktuální přehled. Nové balíky a případy mohou zvětšit celkový rozsah. Dny bez commitů nepřidávají bod. Lokální necommitované změny do historie nevstupují.</p><section class="section"><div class="section-heading"><h2>Denní záznamy</h2>{link('history.json', 'Surová data JSON ↗', 'subtle')}</div>{table(['Den (UTC)', 'Commit', 'Balíky hotovo', 'Brány F1 prošlo', 'Případy prošlo', 'Požadavky splněno'], history_rows, 'Historie progresu')}</section>'''
    completed = ''.join(
        f'<li><span class="mono">{escape(p["id"])}</span><span>{escape(plain(p["title"]))}</span>'
        f'{link("progress.html#package-" + p["id"], "Podrobnosti ↗")}</li>'
        for p in data['packages'] if p['state'] == 'done')
    home_values = {
        'cards': cards, 'phases': phases, 'completed': completed,
        'repository': f'https://github.com/{repository}',
        'plan': source_url(repository, sha, 'PLAN.md'),
        'guide': source_url(repository, sha, 'docs/GUIDE.md'),
        'decisions': source_url(repository, sha, 'docs/DECISIONS.md'),
        'blockers': str(summary['blockers']['states'].get('open', 0)),
    }
    home = re.sub(r'\{\{(\w+)\}\}', lambda m: home_values[m[1]],
                  (ASSETS / 'home.html').read_text(encoding='utf-8'))
    template = (ASSETS / "page.html").read_text(encoding="utf-8")
    pages = {}
    for name, title, body in (("index.html", "Nativní oblasti pro AI agenty na macOS", home),
                             ("progress.html", "Stav vývoje", overview),
                             ("history.html", "Historie vývoje", history_body)):
        values = {"title": title, "body": body, "repository": f"https://github.com/{repository}",
                  "description": "Sanďbox zkoumá nativní izolované oblasti pro AI agenty na macOS. Cíle projektu, navržená architektura a aktuální stav vývoje." if name == 'index.html' else 'Sanďbox: stav implementace, ověřovací brány a historie vývoje.',
                  "coverage": source_url(repository, sha, "docs/COVERAGE.md"),
                  "method": source_url(repository, sha, "docs/PROGRESS.md"), "sha": sha[:7],
                  "snapshot": "Lokální náhled · necommitované změny" if dirty else "Commit " + sha[:7],
                  "home_current": 'aria-current="page"' if name == "index.html" else "",
                  "overview_current": 'aria-current="page"' if name == "progress.html" else "",
                  "history_current": 'aria-current="page"' if name == "history.html" else ""}
        pages[name] = re.sub(r"\{\{(\w+)\}\}", lambda m: values[m[1]] if m[1] in ("body", "home_current", "overview_current", "history_current") else escape(values[m[1]], quote=True), template)
    return pages


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
    pages = render(data, records, repository, head, dirty)
    out.mkdir(parents=True, exist_ok=True)
    for name, html in pages.items():
        (out / name).write_text(html, encoding="utf-8")
    for name, payload in (("progress.json", data), ("history.json", {"schema_version": 1, "ref": sha, "days": records})):
        (out / name).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "progress.svg").write_text(overview_svg(data), encoding="utf-8")
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
