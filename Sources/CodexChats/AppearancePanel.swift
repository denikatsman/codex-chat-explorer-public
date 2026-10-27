import AppKit

private final class AppearanceContent: NSView { override var isFlipped: Bool { true } }

final class AppearancePanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared=AppearancePanel()
    private var panel: NSPanel?
    private var wells=[NSColorWell](),fields=[NSTextField](),labels=[NSTextField]()
    private let choices=NSSegmentedControl(labels:["LIGHT","DARK","GREEN","CUSTOM"],trackingMode:.selectOne,target:nil,action:nil)
    private let note=NSTextField(labelWithString:"Click a swatch or enter #RRGGBB. Changes are saved.")
    private var observer: NSObjectProtocol?
    @objc func show(_ sender: Any? = nil) { if panel == nil { build() };sync();panel?.makeKeyAndOrderFront(nil) }
    private func build() {
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:520,height:520),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="Appearance";panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=false;panel.delegate=self
        let content=AppearanceContent(frame:NSRect(x:0,y:0,width:520,height:520));panel.contentView=content
        choices.frame=NSRect(x:20,y:20,width:480,height:28);choices.target=self;choices.action=#selector(selectPreset);content.addSubview(choices)
        for role in AppearanceRole.allCases {
            let y=CGFloat(72+role.rawValue*43)
            let label=NSTextField(labelWithString:role.title);label.font = .monospacedSystemFont(ofSize:12,weight:.regular);label.frame=NSRect(x:20,y:y+8,width:240,height:22);content.addSubview(label);labels.append(label)
            let well=NSColorWell(frame:NSRect(x:270,y:y,width:72,height:32));well.tag=role.rawValue;well.target=self;well.action=#selector(pickColor);well.isContinuous=true;well.setAccessibilityLabel(role.title+" color");content.addSubview(well);wells.append(well)
            let field=NSTextField(frame:NSRect(x:360,y:y+2,width:140,height:28));field.font = .monospacedSystemFont(ofSize:12,weight:.regular);field.tag=role.rawValue;field.delegate=self;field.setAccessibilityLabel(role.title+" hexadecimal color");content.addSubview(field);fields.append(field)
        }
        note.font = .systemFont(ofSize:11);note.frame=NSRect(x:20,y:429,width:480,height:20);content.addSubview(note)
        let reset=NSButton(title:"Reset Custom",target:self,action:#selector(resetColors));reset.frame=NSRect(x:20,y:469,width:135,height:30);reset.bezelStyle = .rounded;content.addSubview(reset)
        let done=NSButton(title:"Done",target:self,action:#selector(closePanel));done.frame=NSRect(x:410,y:469,width:90,height:30);done.bezelStyle = .rounded;done.keyEquivalent="\r";content.addSubview(done)
        NSColorPanel.shared.showsAlpha=false
        self.panel=panel;panel.center()
        observer=NotificationCenter.default.addObserver(forName:AppearanceSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.sync() }
    }
    private func sync() {
        guard let panel else { return }
        let settings=AppearanceSettings.shared,palette=settings.current
        panel.appearance=NSAppearance(named:palette.isDark ? .darkAqua : .aqua);panel.backgroundColor=palette.background
        panel.contentView?.wantsLayer=true;panel.contentView?.layer?.backgroundColor=palette.background.cgColor
        choices.selectedSegment=settings.isCustom ? 3 : AppTheme.allCases.firstIndex(of:settings.preset) ?? 0
        choices.setEnabled(settings.hasCustom,forSegment:3)
        for role in AppearanceRole.allCases {
            let index=role.rawValue,value=settings.definition.colors[index]
            if !wells[index].isActive { wells[index].color=NativePalette.color(value) }
            if fields[index].currentEditor() == nil { fields[index].stringValue=value }
            fields[index].textColor=palette.text;fields[index].backgroundColor=palette.header;labels[index].textColor=palette.text
        }
        note.textColor=palette.secondary
    }
    @objc private func selectPreset() {
        dismissPicker()
        let value=choices.selectedSegment
        if AppTheme.allCases.indices.contains(value) { AppearanceSettings.shared.choose(AppTheme.allCases[value]) } else { AppearanceSettings.shared.chooseCustom() }
    }
    @objc private func pickColor(_ sender: NSColorWell) {
        guard let role=AppearanceRole(rawValue:sender.tag) else { return }
        let hex=NativePalette.hex(sender.color);fields[sender.tag].stringValue=hex;AppearanceSettings.shared.set(role,hex:hex)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field=notification.object as? NSTextField,let role=AppearanceRole(rawValue:field.tag),let value=AppearancePalette.normalized(field.stringValue) else { return }
        wells[field.tag].color=NativePalette.color(value);AppearanceSettings.shared.set(role,hex:value)
    }
    func controlTextDidEndEditing(_ notification: Notification) { sync() }
    @objc private func resetColors() { dismissPicker();AppearanceSettings.shared.resetCustom() }
    @objc private func closePanel() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        dismissPicker();AppearanceSettings.shared.flush()
    }
    private func dismissPicker() {
        let ownedPicker=wells.contains { $0.isActive };for well in wells { well.deactivate() }
        if ownedPicker { NSColorPanel.shared.orderOut(nil) }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
