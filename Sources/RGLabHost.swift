import Cocoa
import WebKit

let RGLabVersion = "0.9.0"

final class LabDelegate: NSObject, NSApplicationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1500,height:920), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "RG Sibilance Lab"
        window.minSize = NSSize(width:1100,height:720)
        window.center(); window.contentView = web; window.makeKeyAndOrderFront(nil)
        if let u = Bundle.main.url(forResource:"app", withExtension:"html", subdirectory:"Web") { web.loadFileURL(u, allowingReadAccessTo:u.deletingLastPathComponent()) }
        checkUpdate(false)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func checkUpdate(_ manual:Bool) {
        guard let u=URL(string:"https://raw.githubusercontent.com/randygnepa-dev/rg-sibilance-studio/main/webapp/latest.json") else{return}
        URLSession.shared.dataTask(with:u){ data,_,_ in
            guard let data, let j=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let v=j["version"] as? String, let d=j["download"] as? String else{return}
            let newer=v.compare(RGLabVersion,options:.numeric)==.orderedDescending
            DispatchQueue.main.async {
                if newer { let a=NSAlert();a.messageText="RG Sibilance Lab \(v)";a.informativeText="Je dostupná nová verzia.";a.addButton(withTitle:"Stiahnuť");a.addButton(withTitle:"Neskôr");if a.runModal()==.alertFirstButtonReturn,let x=URL(string:d){NSWorkspace.shared.open(x)} }
                else if manual { let a=NSAlert();a.messageText="RG Sibilance Lab \(RGLabVersion) je aktuálny.";a.runModal() }
            }
        }.resume()
    }
}
final class UpdateMenu:NSObject { @objc func check(_ s:Any?){(NSApp.delegate as? LabDelegate)?.checkUpdate(true)} }
let app=NSApplication.shared, delegate=LabDelegate(), updater=UpdateMenu();app.delegate=delegate
let main=NSMenu(), root=NSMenuItem(), menu=NSMenu();main.addItem(root);root.submenu=menu
menu.addItem(withTitle:"About RG Sibilance Lab",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
let u=NSMenuItem(title:"Check for Updates…",action:#selector(UpdateMenu.check(_:)),keyEquivalent:"");u.target=updater;menu.addItem(u);menu.addItem(NSMenuItem.separator());menu.addItem(withTitle:"Quit RG Sibilance Lab",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");app.mainMenu=main;app.run()
