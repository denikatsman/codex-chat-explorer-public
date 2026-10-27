import AppKit

enum AppTheme: String, CaseIterable, Codable {
    case light, dark, green
    var isDark: Bool { self != .light }
    var title: String { self == .light ? "◑ LIGHT" : self == .dark ? "◐ DARK" : "◉ GREEN" }
    static let phosphor = NSColor(srgbRed: 0.12, green: 1, blue: 0.28, alpha: 1)
    static func palette(dark: Bool, green: Bool = false) -> NativePalette { AppearanceSettings.shared.activePalette ?? (green ? NativePalette.green : dark ? NativePalette.dark : NativePalette.light) }
    static func ink(dark: Bool, green: Bool) -> NSColor { palette(dark:dark,green:green).text }
    static func muted(dark: Bool, green: Bool) -> NSColor { palette(dark:dark,green:green).secondary }
    static func background(dark: Bool) -> NSColor { palette(dark:dark).background }
    static func border(dark: Bool, green: Bool = false) -> NSColor { palette(dark:dark,green:green).border }
    static func semantic(_ color: NSColor) -> NSColor { AppearanceSettings.shared.activePalette?.readable(color) ?? color }
}

enum AppearanceRole: Int, CaseIterable {
    case background, text, secondary, canvas, user, assistant, border, accent
    var title: String { ["App background","Primary text","Secondary text","Canvas background","Your message boxes","Assistant message boxes","Borders / dividers","Accent / links"][rawValue] }
}

struct AppearancePalette: Codable, Equatable {
    var colors: [String]
    var isValid: Bool { colors.count == AppearanceRole.allCases.count && colors.allSatisfy { Self.normalized($0) != nil } }
    static func normalized(_ value: String) -> String? {
        let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines),text=trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard text.utf8.count == 6, text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return "#"+text.uppercased()
    }
    static func preset(_ theme: AppTheme) -> Self {
        switch theme {
        case .light: return .init(colors:["#FFFFFF","#000000","#757575","#FFFFFF","#F2F2F2","#FCFCFC","#000000","#1754A6"])
        case .dark: return .init(colors:["#000000","#FFFFFF","#919191","#000000","#1A1A1A","#101010","#FFFFFF","#8AB4FF"])
        case .green: return .init(colors:["#000000","#1FFF47","#14A62E","#000000","#1A1A1A","#101010","#1FFF47","#1FFF47"])
        }
    }
}

final class NativePalette {
    let definition: AppearancePalette
    let background, text, secondary, canvas, user, assistant, border, accent: NSColor
    let code, header, subtleBorder, selection, onSelection: NSColor
    let isDark: Bool
    let web: [String:String]
    private let semanticCache = NSCache<NSString,NSColor>()
    static let light = NativePalette(.preset(.light),custom:false)
    static let dark = NativePalette(.preset(.dark),custom:false)
    static let green = NativePalette(.preset(.green),custom:false)
    init(_ definition: AppearancePalette, custom: Bool) {
        let c=definition.colors.map(Self.color),dark=Self.luminance(c[0]) < 0.4
        let codeColor=Self.mix(c[5],c[1],0.065),lineColor=Self.mix(c[0],c[6],0.24),selected=custom ? c[7] : c[1]
        self.definition=definition; background=c[0];text=c[1];secondary=c[2];canvas=c[3];user=c[4];assistant=c[5];border=c[6];accent=c[7]
        isDark=dark;code=codeColor;header=Self.mix(c[0],c[1],0.07);subtleBorder=lineColor;selection=selected
        onSelection=Self.contrast(.white,selected)>Self.contrast(.black,selected) ? .white : .black
        let syntax:[(String,String,String)]=[("keyword","#C69CE0","#7B36A5"),("string","#94C990","#297135"),("number","#D4B27A","#916016"),("title","#83BDF1","#1754A6"),("comment","#929292","#696969"),("variable","#E7A18E","#A54A36")]
        var tokens=["paper":Self.hex(c[0]),"ink":Self.hex(c[1]),"muted":Self.hex(c[2]),"user":Self.hex(c[4]),"assistant":Self.hex(c[5]),"line":Self.hex(lineColor),"code":Self.hex(codeColor),"link":Self.hex(c[7]),"diagram-fill":Self.hex(Self.mix(c[5],c[7],0.12))]
        for (name,darkHex,lightHex) in syntax { tokens["syntax-"+name]=Self.hex(Self.adjust(Self.color(dark ? darkHex : lightHex),against:codeColor)) }
        web=tokens;semanticCache.countLimit=256
    }
    func readable(_ color: NSColor) -> NSColor {
        let key=Self.hex(color) as NSString
        if let value=semanticCache.object(forKey:key) { return value }
        let value=Self.adjust(color,against:background);semanticCache.setObject(value,forKey:key);return value
    }
    static func color(_ hex: String) -> NSColor {
        let value=UInt32(hex.dropFirst(),radix:16) ?? 0
        return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
    }
    static func hex(_ color: NSColor) -> String {
        let c=color.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> Int { value.isFinite ? Int(round(min(1,max(0,value))*255)) : 0 }
        return String(format:"#%02X%02X%02X",byte(c.redComponent),byte(c.greenComponent),byte(c.blueComponent))
    }
    static func mix(_ a: NSColor,_ b: NSColor,_ fraction: CGFloat) -> NSColor {
        let a=a.usingColorSpace(.sRGB) ?? .black,b=b.usingColorSpace(.sRGB) ?? .white
        return NSColor(srgbRed:a.redComponent*(1-fraction)+b.redComponent*fraction,green:a.greenComponent*(1-fraction)+b.greenComponent*fraction,blue:a.blueComponent*(1-fraction)+b.blueComponent*fraction,alpha:1)
    }
    static func luminance(_ color: NSColor) -> CGFloat {
        let c=color.usingColorSpace(.sRGB) ?? .black
        func linear(_ v: CGFloat) -> CGFloat { v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
    }
    static func contrast(_ a: NSColor,_ b: NSColor) -> CGFloat { let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05) }
    static func adjust(_ color: NSColor,against background: NSColor) -> NSColor {
        if contrast(color,background)>=4.5 { return color }
        let target:NSColor=contrast(.white,background)>contrast(.black,background) ? .white : .black
        for n in 1...20 { let value=mix(color,target,CGFloat(n)/20);if contrast(value,background)>=4.5 { return value } }
        return target
    }
}

final class AppearanceSettings {
    static let shared=AppearanceSettings()
    static let changed=Notification.Name("ExplorerAppearanceChanged")
    private struct Saved: Codable { var preset: AppTheme;var custom: AppearancePalette?;var useCustom: Bool }
    private var saved: Saved
    private var active=false
    private(set) var activePalette: NativePalette?
    private var persistence: DispatchWorkItem?
    private var publishing=false
    var preset: AppTheme { saved.preset }
    var isCustom: Bool { active && saved.useCustom && activePalette != nil }
    var hasCustom: Bool { saved.custom != nil }
    var definition: AppearancePalette { isCustom ? saved.custom! : .preset(saved.preset) }
    var current: NativePalette { activePalette ?? AppTheme.palette(dark:saved.preset.isDark,green:saved.preset == .green) }
    private init() {
        let preset=UserDefaults.standard.string(forKey:"colorTheme").flatMap(AppTheme.init(rawValue:)) ?? (UserDefaults.standard.bool(forKey:"darkMode") ? .dark : .light)
        saved=Saved(preset:preset,custom:nil,useCustom:false)
        if let data=UserDefaults.standard.data(forKey:"appearancePaletteV1"),var value=try? JSONDecoder().decode(Saved.self,from:data),value.custom?.isValid != false {
            if let palette=value.custom { value.custom=AppearancePalette(colors:palette.colors.compactMap(AppearancePalette.normalized)) };saved=value
        }
    }
    func activate() { active=true;resolve() }
    private func resolve() { activePalette=active && saved.useCustom ? saved.custom.map { NativePalette($0,custom:true) } : nil }
    func choose(_ preset: AppTheme) { saved.preset=preset;saved.useCustom=false;update() }
    func chooseCustom() { guard saved.custom != nil else { return };saved.useCustom=true;update() }
    func set(_ role: AppearanceRole,hex: String) {
        guard let hex=AppearancePalette.normalized(hex) else { return }
        var palette=saved.useCustom ? saved.custom ?? .preset(saved.preset) : .preset(saved.preset)
        guard palette.colors[role.rawValue] != hex || !saved.useCustom else { return }
        palette.colors[role.rawValue]=hex;saved.custom=palette;saved.useCustom=true;update()
    }
    func resetCustom() { saved.custom = .preset(saved.preset);saved.useCustom=true;update() }
    private func update() {
        resolve()
        if !publishing { publishing=true;DispatchQueue.main.asyncAfter(deadline:.now()+0.03) { [weak self] in self?.publishing=false;NotificationCenter.default.post(name:Self.changed,object:nil) } }
        persistence?.cancel();let work=DispatchWorkItem { [weak self] in self?.flush() };persistence=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    func flush() {
        guard active else { return }
        persistence?.cancel();persistence=nil
        if let data=try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data,forKey:"appearancePaletteV1") }
        UserDefaults.standard.set(saved.preset.rawValue,forKey:"colorTheme")
    }
}
