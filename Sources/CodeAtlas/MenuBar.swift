import AppKit

extension AppDelegate {
    func makeStatusItem() {
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem=item
        let icon=NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            NSColor.black.setFill()
            // Four map tiles: a recognizable atlas silhouette in a single ink.
            for r in [NSRect(x:1,y:9,width:7,height:8),NSRect(x:10,y:12,width:7,height:5),NSRect(x:1,y:1,width:7,height:6),NSRect(x:10,y:1,width:7,height:9)] {
                NSBezierPath(roundedRect:r,xRadius:1.2,yRadius:1.2).fill()
            }
            return true
        }
        icon.isTemplate=true; item.button?.image=icon; item.button?.toolTip="Code Atlas"
        item.button?.setAccessibilityLabel("Code Atlas menu")
        let menu=NSMenu()
        let show=NSMenuItem(title:"Open Code Atlas",action:#selector(showAtlas),keyEquivalent:""); show.target=self; menu.addItem(show)
        let folder=NSMenuItem(title:"Open Folder…",action:#selector(statusOpenFolder),keyEquivalent:""); folder.target=self; menu.addItem(folder)
        menu.addItem(.separator())
        let quit=NSMenuItem(title:"Quit Code Atlas",action:#selector(NSApplication.terminate(_:)),keyEquivalent:""); menu.addItem(quit)
        item.menu=menu
    }
    @objc func showAtlas() {window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)}
    @objc func statusOpenFolder() {showAtlas(); chooseProject()}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showAtlas();return true}
}
