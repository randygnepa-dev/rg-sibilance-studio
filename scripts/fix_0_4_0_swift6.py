from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
# Swift 6 parses member assignments strictly; normalize all '=.' occurrences.
s=s.replace('=.',' = .')
p.write_text(s)
print('normalized Swift 6 member assignment spacing')
