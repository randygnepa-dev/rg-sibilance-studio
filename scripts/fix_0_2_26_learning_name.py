from pathlib import Path
for fn in ['Sources/RGSibilanceStudio.swift','Sources/RGAdvancedEngine.swift']:
    p=Path(fn)
    s=p.read_text()
    s=s.replace('RGLearningStore','RGExemplarStore')
    p.write_text(s)
