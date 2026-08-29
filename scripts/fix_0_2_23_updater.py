from pathlib import Path
p=Path('Sources/RGSibilanceStudio.swift')
s=p.read_text()
assert 'let RGVersion = "0.2.23"' in s
old='''                let source = base.appendingPathComponent("RGSibilanceStudio-\\(version).swift")\n                let binary = base.appendingPathComponent("RG Sibilance Studio-\\(version)")\n                let marker = base.appendingPathComponent("UPDATED_TO")\n                try data.write(to: source, options: .atomic)'''
new='''                let source = base.appendingPathComponent("RGSibilanceStudio-\\(version).swift")\n                let helper = base.appendingPathComponent("RGAdvancedEngine-\\(version).swift")\n                let binary = base.appendingPathComponent("RG Sibilance Studio-\\(version)")\n                let marker = base.appendingPathComponent("UPDATED_TO")\n                try data.write(to: source, options: .atomic)\n                guard let helperURL = URL(string: "\\(RGRepoRaw)/Sources/RGAdvancedEngine.swift?t=\\(Date().timeIntervalSince1970)") else { self.busy = false; return }\n                let helperData = try Data(contentsOf: helperURL)\n                try helperData.write(to: helper, options: .atomic)'''
assert old in s
s=s.replace(old,new,1)
old='''                p.arguments = ["--sdk", "macosx", "swiftc", source.path, "-sdk", sdk, "-o", binary.path, "-framework", "Cocoa", "-framework", "AVFoundation"]'''
new='''                p.arguments = ["--sdk", "macosx", "swiftc", source.path, helper.path, "-sdk", sdk, "-o", binary.path, "-framework", "Cocoa", "-framework", "AVFoundation"]'''
assert old in s
s=s.replace(old,new,1)
p.write_text(s)
print('updater fixed')
