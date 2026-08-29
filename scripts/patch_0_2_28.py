from pathlib import Path
p = Path('Sources/RGSibilanceStudio.swift')
s = p.read_text()
s = s.replace('let RGVersion = "0.2.27"', 'let RGVersion = "0.2.28"', 1)
if 'let RGVersion = "0.2.28"' not in s:
    raise SystemExit('version patch failed')
p.write_text(s)
