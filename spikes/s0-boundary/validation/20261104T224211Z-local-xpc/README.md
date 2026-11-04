# Vývojová validace vlastní XPC fixture — 2026-11-04

Nejde o L2, S0 ani akceptační důkaz. Raw serverové záznamy a preregistrace jsou z vlastních syntetických procesů.
`final`: 42 native Release XCTest, 6 živých případů, všechny service exits pozorované NOTE_EXIT, všechny own clients reaped, všechny dočasné bundles odstraněné.
`receipt-recheck`: jeden dodatečný pozitivní/denial případ po doplnění file flags do cleanup receipts a odmítnutí Python -O. Swift runtime se nezměnil.
Přesná metodika, předchozí neúplné pokusy a limity jsou v ../../VALIDATION.md a ../../XPC-FIXTURE.md.
Peer auditUID/token nejsou veřejným API dostupné; same-UID/session fixture je nedokazuje.

Záznamy se následnými výsledky nepřepisují. Manifest zahrnuje každý soubor kromě sebe.
