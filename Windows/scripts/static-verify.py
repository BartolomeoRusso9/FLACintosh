#!/usr/bin/env python3
"""Dependency-free static checks for the WinUI project when dotnet is unavailable."""
from pathlib import Path
import re, sys, xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
errors = []
for p in ROOT.joinpath("src/MusicPlayerWin.App").rglob("*.xaml"):
    try: ET.parse(p)
    except Exception as exc: errors.append(f"XAML parse failed: {p}: {exc}")
for xaml in ROOT.joinpath("src/MusicPlayerWin.App").rglob("*.xaml"):
    if xaml.name == "App.xaml": continue
    handlers = re.findall(r'\b(?:Click|Tapped|SelectionChanged|ItemClick|TextChanged|QuerySubmitted|ValueChanged|KeyDown|DragOver|Drop|Closing)="([A-Za-z_][A-Za-z0-9_]*)"', xaml.read_text(errors="ignore"))
    code = xaml.with_suffix(".xaml.cs").read_text(errors="ignore") if xaml.with_suffix(".xaml.cs").exists() else ""
    for h in handlers:
        if not re.search(r'\b' + re.escape(h) + r'\s*\(', code): errors.append(f"Missing handler {h} in {xaml}")
app = ROOT.joinpath("src/MusicPlayerWin.App/Services/AppServices.cs").read_text(errors="ignore")
publics = set(re.findall(r'\bpublic\s+(?:static\s+)?(?:async\s+)?(?:Task(?:<[^>]+>)?|ValueTask(?:<[^>]+>)?|IReadOnlyList<[^>]+>|IReadOnlyDictionary<[^>]+>|[A-Za-z0-9_?.<>\[\],]+)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|=>|\{)', app))
publics.update(re.findall(r'\bpublic\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{', app))
refs=set()
for p in ROOT.joinpath("src/MusicPlayerWin.App").rglob("*.cs"):
    refs.update(re.findall(r'App\.Services\.([A-Za-z_][A-Za-z0-9_]*)', p.read_text(errors="ignore")))
allowed_events={"ErrorRaised","LibraryChanged","PlayerStateChanged","PlaylistsChanged","SettingsChanged"}
for r in sorted((refs-publics)-allowed_events): errors.append(f"Unknown App.Services member {r}")
for p in [*ROOT.joinpath("src").rglob("*.cs"), *ROOT.joinpath("src").rglob("*.xaml")]:
    t=p.read_text(errors="ignore")
    if re.search(r'NotImplementedException|TODO|FIXME|coming soon', t, re.I): errors.append(f"Placeholder marker in {p}")
print(f"Static verification: {'PASS' if not errors else 'FAIL'}")
for e in errors: print(e)
sys.exit(1 if errors else 0)
