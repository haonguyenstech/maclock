import Cocoa
import SwiftUI
import LocalAuthentication
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import IOKit.pwr_mgt

// ============ Danh sách màn hình đang hoạt động ============
func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

// ============ Chống ngủ (Option A: không cho native lock chen vào) ============
var sleepAssertion: IOPMAssertionID = 0
func preventDisplaySleep(_ on: Bool) {
    if on {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "MacLock is locked" as CFString, &sleepAssertion)
    } else if sleepAssertion != 0 {
        IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
    }
}

// ============ Điều khiển đèn nền (DisplayServices riêng, best-effort) ============
final class Backlight {
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    static let shared = Backlight()
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var saved: [UInt32: Float] = [:]
    private(set) var dimmed = false
    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let h = dlopen(path, RTLD_NOW) else { return }
        if let g = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(g, to: GetFn.self) }
        if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: SetFn.self) }
    }
    func dim() {
        guard let setFn else { return }
        if !dimmed {
            if let getFn { for id in activeDisplays() { var b: Float = 0; if getFn(id, &b) == 0 { saved[id] = b } } }
            dimmed = true
        }
        for id in activeDisplays() { _ = setFn(id, 0) }   // ép về 0, chống hệ thống kéo sáng lại
    }
    func restore() {
        guard let setFn else { return }
        // Khôi phục theo MÀN HÌNH ĐANG HOẠT ĐỘNG (ID có thể đổi sau khi wake).
        // Không bao giờ khôi phục về ~0 -> tránh kẹt màn đen.
        let fallback = max(saved.values.max() ?? 0.7, 0.4)
        for id in activeDisplays() {
            let target = saved[id] ?? fallback
            _ = setFn(id, target < 0.05 ? fallback : target)
        }
        saved.removeAll(); dimmed = false
    }
    // Bảo hiểm: nếu đèn nền còn ~0 thì kéo lên mức nhìn được (gọi sau khi wake)
    func ensureVisible() {
        guard let getFn, let setFn else { return }
        for id in activeDisplays() {
            var b: Float = 0
            if getFn(id, &b) == 0 && b < 0.05 { _ = setFn(id, 0.7) }
        }
    }
}

// ============ Login Item (khởi động cùng hệ thống) ============
func loginItemEnabled() -> Bool {
    if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
    return false
}
func setLoginItem(_ on: Bool) {
    guard #available(macOS 13, *) else { return }
    do {
        if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
        else  { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } }
    } catch { NSLog("MacLock login item error: \(error)") }
}

// ============ Shared state ============
final class LockModel: ObservableObject {
    @Published var password = ""
    @Published var wrong = false
    @Published var errorText = ""      // báo sai mật khẩu dưới ô input
    @Published var tapActive = false   // true = event tap đang chặn phím
    @Published var blackout = false    // true = MacLock đang tối đen màn hình
    var onSubmit: () -> Void = {}
    var onTouchID: () -> Void = {}
}
let lockModel = LockModel()
var appDelegate: AppDelegate!    // set trong main

// ============ Global hotkey (Carbon) ============
var hotKeyRef: EventHotKeyRef?
var hotkeyHandlerInstalled = false

func carbonMods(from f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option)  { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}
func modSymbols(_ m: NSEvent.ModifierFlags) -> String {
    var s = ""
    if m.contains(.control) { s += "⌃" }
    if m.contains(.option)  { s += "⌥" }
    if m.contains(.shift)   { s += "⇧" }
    if m.contains(.command) { s += "⌘" }
    return s
}
func savedHotkey() -> (keyCode: UInt32, mods: NSEvent.ModifierFlags, display: String) {
    let d = UserDefaults.standard
    if d.object(forKey: "hkKeyCode") != nil {
        let kc = UInt32(d.integer(forKey: "hkKeyCode"))
        let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hkModRaw")))
        let disp = d.string(forKey: "hkDisplay") ?? "⌃⌥L"
        return (kc, mods, disp)
    }
    return (37, [.control, .option], "⌃⌥L")   // mặc định ⌃⌥L (L = keycode 37)
}
func saveHotkey(keyCode: UInt16, mods: NSEvent.ModifierFlags, display: String) {
    let d = UserDefaults.standard
    d.set(Int(keyCode), forKey: "hkKeyCode")
    d.set(Int(mods.rawValue), forKey: "hkModRaw")
    d.set(display, forKey: "hkDisplay")
    appDelegate?.applyHotkey()
}
func registerHotkey(keyCode: UInt32, carbon: UInt32) {
    if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    if !hotkeyHandlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, _, _) -> OSStatus in
            DispatchQueue.main.async { appDelegate?.lock() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
        hotkeyHandlerInstalled = true
    }
    let hkID = EventHotKeyID(signature: OSType(0x4d4c4b31), id: 1)   // 'MLK1'
    RegisterEventHotKey(keyCode, carbon, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
}

// ============ Key recorder (bắt tổ hợp phím mới) ============
final class RecorderView: NSView {
    var onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void = { _,_,_ in }
    var onRecordingChange: (Bool) -> Void = { _ in }
    var recording = false { didSet { onRecordingChange(recording) } }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { recording = true; window?.makeFirstResponder(self) }
    override func keyDown(with e: NSEvent) {
        guard recording else { return }
        if e.keyCode == 53 { recording = false; window?.makeFirstResponder(nil); return }  // Esc huỷ
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { NSSound.beep(); return }   // yêu cầu ít nhất 1 phím bổ trợ
        let ch = (e.charactersIgnoringModifiers ?? "").uppercased()
        onCapture(e.keyCode, mods, modSymbols(mods) + ch)
        recording = false
        window?.makeFirstResponder(nil)
    }
    override func resignFirstResponder() -> Bool { recording = false; return true }
}
struct Recorder: NSViewRepresentable {
    var onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void
    var onRecordingChange: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView(); v.onCapture = onCapture; v.onRecordingChange = onRecordingChange; return v
    }
    func updateNSView(_ v: RecorderView, context: Context) {
        v.onCapture = onCapture; v.onRecordingChange = onRecordingChange
    }
}

// ============ Settings window (UI cao cấp kiểu macOS) ============
struct AppBadge: View {
    var size: CGFloat = 52
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.98),
                                          Color(red: 0.16, green: 0.26, blue: 0.85)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "lock.fill")
                .font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

struct SettingRow<Trailing: View>: View {
    let icon: String, tint: Color, title: String, subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct SettingsView: View {
    @State private var display = savedHotkey().display
    @State private var recording = false
    @State private var launchAtLogin = loginItemEnabled()
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("blackoutMinutes") private var blackoutMinutes = 5

    var body: some View {
        VStack(spacing: 0) {
            // ---- Header ----
            HStack(spacing: 14) {
                AppBadge()
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacLock").font(.system(size: 20, weight: .bold))
                    Text("Lock screen with Touch ID").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)

            // ---- Card GENERAL ----
            VStack(alignment: .leading, spacing: 6) {
                Text("GENERAL").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    SettingRow(icon: "command", tint: .blue,
                               title: "Quick-Lock Shortcut",
                               subtitle: "Press anywhere to lock instantly") {
                        recorderPill
                    }
                    Divider().padding(.leading, 52)
                    SettingRow(icon: "dock.rectangle", tint: .indigo,
                               title: "Show in Dock",
                               subtitle: "Off = menu bar only") {
                        Toggle("", isOn: $showInDock).labelsHidden().toggleStyle(.switch)
                            .onChange(of: showInDock) { appDelegate?.applyDockVisibility() }
                    }
                    Divider().padding(.leading, 52)
                    SettingRow(icon: "moon.fill", tint: .purple,
                               title: "Dim Screen After",
                               subtitle: "Blackout while locked (saves power)") {
                        Picker("", selection: $blackoutMinutes) {
                            Text("Never").tag(0)
                            Text("1 min").tag(1)
                            Text("2 min").tag(2)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    Divider().padding(.leading, 52)
                    SettingRow(icon: "power", tint: .green,
                               title: "Launch at Login",
                               subtitle: "Start automatically after restart") {
                        Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                            .onChange(of: launchAtLogin) {
                                setLoginItem(launchAtLogin)
                                launchAtLogin = loginItemEnabled()   // đồng bộ lại trạng thái thật
                            }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            .padding(.horizontal, 20)

            // ---- Footer ----
            HStack(spacing: 10) {
                Button { appDelegate?.lock() } label: {
                    Label("Lock Now", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var recorderPill: some View {
        ZStack {
            Capsule().fill(recording ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            Capsule().stroke(recording ? Color.accentColor : Color.primary.opacity(0.15),
                             lineWidth: recording ? 1.5 : 1)
            Text(recording ? "Press keys…" : display)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .allowsHitTesting(false)
            Recorder(onCapture: { keyCode, mods, disp in
                saveHotkey(keyCode: keyCode, mods: mods, display: disp)
                display = disp
            }, onRecordingChange: { recording = $0 })
        }
        .frame(width: 96, height: 28)
    }
}

// ============ Cache wallpaper đã blur (chỉ tính 1 lần / lần khóa) ============
var lockBackground: NSImage?

// ============ Borderless window nhận được bàn phím ============
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// ============ Avatar (bundle -> /tmp fallback) ============
func loadAvatar() -> NSImage? {
    if let p = Bundle.main.path(forResource: "avatar", ofType: "jpg"),
       let img = NSImage(contentsOfFile: p) { return img }
    return NSImage(contentsOfFile: "/tmp/lock_avatar.jpg")
}

// ============ Blurred wallpaper ============
func currentWallpaperBlurred() -> NSImage {
    let ws = NSWorkspace.shared
    var img: NSImage?
    if let screen = NSScreen.main, let url = ws.desktopImageURL(for: screen) { img = NSImage(contentsOf: url) }
    let base = img ?? NSImage(size: NSScreen.main?.frame.size ?? .init(width: 1728, height: 1117))
    guard let tiff = base.tiffRepresentation, let ci = CIImage(data: tiff) else { return base }
    let blur = CIFilter(name: "CIGaussianBlur")!
    blur.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(22.0, forKey: kCIInputRadiusKey)
    let out = blur.outputImage!.cropped(to: ci.extent)
    let rep = NSCIImageRep(ciImage: out)
    let result = NSImage(size: rep.size); result.addRepresentation(rep)
    return result
}

// ============ CGEventTap callback (nuốt toàn bộ phím) ============
func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                 event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // Hệ thống tự tắt tap -> bật lại
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = appDelegate?.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // Chưa khóa -> để mọi thứ đi bình thường
    guard appDelegate?.locked == true else { return Unmanaged.passUnretained(event) }

    appDelegate?.noteActivity()   // mọi thao tác -> thoát tối màn hình + reset đồng hồ idle

    switch type {
    case .keyDown:
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasCmdCtrlOptFn = !flags.intersection([.maskCommand, .maskControl,
                                                   .maskAlternate, .maskSecondaryFn]).isEmpty
        var len = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        let chars = String(utf16CodeUnits: buf, count: len)
        DispatchQueue.main.async {
            appDelegate?.handleKey(keycode: keycode, chars: chars, modified: hasCmdCtrlOptFn)
        }
        return nil                                  // nuốt phím
    case .keyUp, .flagsChanged, .scrollWheel:
        return nil                                  // nuốt phím + cuộn/vuốt 2 ngón
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        // Chặn hot corner: nuốt di chuyển khi con trỏ chạm sát góc màn hình
        return appDelegate?.inHotCorner(event.location) == true ? nil : Unmanaged.passUnretained(event)
    default:
        return nil                                  // gesture/swipe đa chạm (Mission Control/Spaces)
    }
}

// ============ SwiftUI lock view (chuẩn Tahoe) ============
struct LockView: View {
    var onSuccess: () -> Void
    @ObservedObject var model = lockModel
    @State private var time = ""
    @State private var date = ""
    @FocusState private var focused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Image(nsImage: lockBackground ?? NSImage())   // đã blur sẵn -> body nhẹ, không lag
                .resizable().scaledToFill()
                .overlay(Color.black.opacity(0.15))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: -4) {
                    Text(date).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    Text(time).font(.system(size: 96, weight: .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                }.padding(.top, 60)

                Spacer()

                VStack(spacing: 12) {
                    avatar
                    Text(NSFullUserName()).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)

                    // Ô mật khẩu: tap BẬT -> hiển thị chấm (bơm qua handleKey);
                    //             tap TẮT -> SecureField thật để gõ trực tiếp
                    HStack(spacing: 6) {
                        if model.tapActive {
                            Text(model.password.isEmpty ? "Enter Password"
                                                         : String(repeating: "•", count: model.password.count))
                                .font(.system(size: 14))
                                .foregroundStyle(model.password.isEmpty ? .white.opacity(0.55) : .white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            SecureField("Enter Password", text: $model.password)
                                .textFieldStyle(.plain).font(.system(size: 14))
                                .foregroundStyle(.white).focused($focused)
                                .onSubmit { model.onSubmit() }
                                .onChange(of: model.password) {
                                    if model.wrong && !model.password.isEmpty { model.wrong = false; model.errorText = "" }
                                }
                        }
                        Button(action: model.onSubmit) {
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.white.opacity(0.18)))
                        }.buttonStyle(.plain)
                    }
                    .padding(.leading, 16).padding(.trailing, 5)
                    .frame(width: 230, height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(model.wrong ? Color.red.opacity(0.9)
                                                          : .white.opacity(0.35), lineWidth: model.wrong ? 1.2 : 0.8))

                    // Dưới ô input: sai -> báo lỗi đỏ (không ảnh hưởng màn hình)
                    if model.wrong {
                        Text(model.errorText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.95))
                    }

                    // Nút Touch ID CỐ ĐỊNH — luôn bấm được để kích hoạt vân tay
                    Button(action: model.onTouchID) {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid").font(.system(size: 18, weight: .semibold))
                            Text("Touch ID").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }

                Spacer(); Spacer()
            }

            // Lớp tối đen do MacLock quản (thay cho display-sleep của hệ thống)
            if model.blackout {
                Color.black.ignoresSafeArea().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.blackout)
        .onAppear {
            tick(); model.onTouchID()
            if !model.tapActive { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } }
        }
        .onReceive(timer) { _ in tick() }
    }

    var avatar: some View {
        Group {
            if let img = loadAvatar() {
                Image(nsImage: img).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.circle.fill").resizable() }
        }
        .frame(width: 76, height: 76).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1)).shadow(radius: 8)
    }

    func tick() {
        let f = DateFormatter(); f.locale = Locale.current
        f.dateFormat = "H:mm"; time = f.string(from: Date())
        f.dateFormat = "EEEE d MMMM"; date = f.string(from: Date())
    }
}

// ============ App delegate ============
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var wins: [NSWindow] = []
    var locked = false
    var eventTap: CFMachPort?
    var settingsWin: NSWindow?
    var watchdog: Timer?
    var lastActivity = Date()
    let lockOptions: NSApplication.PresentationOptions =
        [.disableForceQuit, .disableProcessSwitching, .disableSessionTermination,
         .hideDock, .hideMenuBar, .disableAppleMenu, .disableHideApplication]

    func applyHotkey() {
        let hk = savedHotkey()
        registerHotkey(keyCode: hk.keyCode, carbon: carbonMods(from: hk.mods))
    }

    func applyDockVisibility() {
        let d = UserDefaults.standard
        let show = d.object(forKey: "showInDock") == nil ? true : d.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate(ignoringOtherApps: true) }
        // giữ cửa sổ Settings hiển thị sau khi đổi policy
        if let w = settingsWin, w.isVisible {
            DispatchQueue.main.async { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Lock")
            b.image?.isTemplate = true
            b.action = #selector(clicked(_:)); b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        lockModel.onSubmit  = { [weak self] in self?.verifyPassword() }
        lockModel.onTouchID = { [weak self] in self?.touchID() }
        applyHotkey()          // đăng ký phím tắt khóa nhanh (mặc định ⌃⌥L)
        applyDockVisibility()  // ẩn/hiện Dock theo cài đặt
        ensureAccessibility()

        // Wake máy/màn hình -> luôn bật sáng + thoát tối (sự kiện wake KHÔNG qua event tap)
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        wc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        // tự mở Settings khi chạy kèm --settings (tiện xem nhanh)
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    @objc func systemDidWake() {
        guard locked else { return }
        exitBlackout()             // bật sáng lại + thoát tối
        lastActivity = Date()      // cho lại trọn thời gian idle trước khi tối lần nữa
        reassert()                 // đảm bảo cửa sổ khóa vẫn ở trên cùng
        // bảo hiểm: nếu panel chưa kịp sáng, kéo lên sau 0.6s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if self.locked { Backlight.shared.ensureVisible() }
        }
    }

    @objc func openSettings() {
        if settingsWin == nil {
            let host = NSHostingView(rootView: SettingsView())
            host.setFrameSize(host.fittingSize)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = host
            w.center(); w.isReleasedWhenClosed = false
            settingsWin = w
        }
        settingsWin?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ---- Xin quyền Accessibility (bắt buộc để nuốt phím) ----
    func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("⚠️  Accessibility permission required — grant it, then relaunch to block the keyboard.")
        }
    }

    // ---- Menu bar click ----
    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { lock() }
    }
    func showMenu() {
        let m = NSMenu()
        let lockItem = NSMenuItem(title: "Lock Now  (\(savedHotkey().display))", action: #selector(lock), keyEquivalent: "")
        m.addItem(lockItem)
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil
    }

    // ---- Lock ----
    @objc func lock() {
        guard !locked else { return }
        locked = true
        lockModel.password = ""; lockModel.wrong = false; lockModel.errorText = ""
        lockBackground = currentWallpaperBlurred()   // blur 1 lần duy nhất ở đây
        lockModel.blackout = false
        lastActivity = Date()
        preventDisplaySleep(true)          // Option A: chặn native lock chen vào
        startTap()
        NSApp.presentationOptions = lockOptions
        coverAllScreens()
        NSApp.activate(ignoringOtherApps: true)

        // Phủ màn hình mới cắm vào khi đang khóa
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Watchdog: giữ tap sống + khóa luôn ở trên cùng, chống cướp focus / tap bị tắt
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reassert()
        }
    }

    // Tạo cửa sổ khóa cho mọi màn hình chưa được phủ
    func coverAllScreens() {
        let covered = Set(wins.compactMap { $0.screen })
        for s in NSScreen.screens where !covered.contains(s) {
            let w = LockWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = true; w.backgroundColor = .black
            w.contentView = NSHostingView(rootView: LockView(onSuccess: { [weak self] in self?.unlock() }))
            w.setFrame(s.frame, display: true); w.makeKeyAndOrderFront(nil)
            wins.append(w)
        }
    }
    @objc func screensChanged() { guard locked else { return }; coverAllScreens() }

    // Con trỏ có đang sát góc màn hình nào không (toạ độ CG, gốc trên-trái)
    func inHotCorner(_ p: CGPoint) -> Bool {
        let m: CGFloat = 5
        for id in activeDisplays() {
            let b = CGDisplayBounds(id)
            for c in [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                      CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)] {
                if abs(p.x - c.x) < m && abs(p.y - c.y) < m { return true }
            }
        }
        return false
    }

    // Định kỳ tái khẳng định trạng thái khóa (không cướp key của hộp thoại Touch ID)
    func reassert() {
        guard locked else { return }
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        } else { startTap() }                       // tap chết -> dựng lại
        if NSApp.presentationOptions != lockOptions { NSApp.presentationOptions = lockOptions }
        let shield = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        for w in wins where w.level != shield || !w.isVisible {
            w.level = shield; w.orderFrontRegardless()   // đẩy lên lại nếu bị đè, KHÔNG makeKey
        }
        // ---- Cơ chế tối màn hình do MacLock quản ----
        let d = UserDefaults.standard
        let mins = d.object(forKey: "blackoutMinutes") == nil ? 5 : d.integer(forKey: "blackoutMinutes")
        if lockModel.blackout {
            Backlight.shared.dim()               // giữ đèn nền ở 0 (chống hệ thống kéo sáng)
        } else if mins > 0 && Date().timeIntervalSince(lastActivity) >= Double(mins * 60) {
            enterBlackout()
        }
    }

    // ---- Hoạt động của người dùng khi đang khóa (từ event tap) ----
    func noteActivity() {
        lastActivity = Date()
        if lockModel.blackout { exitBlackout() }
    }
    func enterBlackout() { lockModel.blackout = true;  Backlight.shared.dim() }
    func exitBlackout()  { Backlight.shared.restore(); lockModel.blackout = false; lastActivity = Date() }

    func unlock() {
        rearmWork?.cancel(); rearmWork = nil
        currentLA?.invalidate(); currentLA = nil
        Backlight.shared.restore()         // trả lại độ sáng
        preventDisplaySleep(false)         // cho hệ thống ngủ lại như thường
        lockModel.blackout = false
        watchdog?.invalidate(); watchdog = nil
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        stopTap()
        NSApp.presentationOptions = []
        wins.forEach { $0.orderOut(nil) }; wins.removeAll()
        locked = false
    }

    // ---- CGEventTap: nuốt toàn bộ phím ----
    func startTap() {
        guard eventTap == nil else { return }
        // Bàn phím + cuộn/vuốt + kéo chuột + gesture đa chạm (Mission Control/Spaces)
        let bits: [UInt64] = [
            UInt64(CGEventType.keyDown.rawValue), UInt64(CGEventType.keyUp.rawValue),
            UInt64(CGEventType.flagsChanged.rawValue), UInt64(CGEventType.scrollWheel.rawValue),
            UInt64(CGEventType.mouseMoved.rawValue), UInt64(CGEventType.leftMouseDragged.rawValue),
            UInt64(CGEventType.rightMouseDragged.rawValue), UInt64(CGEventType.otherMouseDragged.rawValue),
            29, 30, 31   // gesture, magnify, swipe (đa chạm)
        ]
        var mask: UInt64 = 0
        for b in bits { mask |= (1 << b) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: tapCallback, userInfo: nil) else {
            print("❌ Could not create event tap — Accessibility permission is missing.")
            lockModel.tapActive = false     // -> LockView hiện SecureField để gõ thủ công
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lockModel.tapActive = true          // -> chặn phím + bơm mật khẩu qua handleKey
    }
    func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        lockModel.tapActive = false
    }

    // ---- Nhập phím (từ tap bơm sang) ----
    func handleKey(keycode: Int64, chars: String, modified: Bool) {
        if lockModel.wrong { lockModel.wrong = false; lockModel.errorText = "" }  // gõ lại -> xóa lỗi
        switch keycode {
        case 36, 76: verifyPassword()                                   // Return / Enter
        case 51: if !lockModel.password.isEmpty { lockModel.password.removeLast() } // Delete
        case 53: break                                                  // Escape -> bỏ qua
        default:
            if modified { break }                                       // bỏ qua combo shortcut
            if !chars.isEmpty && chars.first!.isNewline == false { lockModel.password += chars }
        }
    }

    // ---- Xác thực ----
    var currentLA: LAContext?
    var rearmWork: DispatchWorkItem?
    func touchID() {
        guard locked else { return }
        currentLA?.invalidate()                            // hủy phiên cũ nếu còn treo
        let ctx = LAContext(); currentLA = ctx
        ctx.localizedFallbackTitle = ""                    // ẩn nút "Enter Password" trong hộp thoại
        var e: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock the screen") { ok, err in
            DispatchQueue.main.async {
                if ok { self.unlock(); return }
                // GIỮ VÂN TAY LUÔN SẴN SÀNG: sai ngón/timeout -> tự mở lại phiên
                // (nếu bạn CHỦ ĐỘNG bấm Cancel thì thôi, để còn gõ mật khẩu)
                guard self.locked else { return }
                let code = (err as? LAError)?.code
                if code != .userCancel && code != .systemCancel && code != .appCancel {
                    self.rearmWork?.cancel()
                    let w = DispatchWorkItem { self.touchID() }
                    self.rearmWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
                }
            }
        }
    }
    func verifyPassword() {
        let pass = lockModel.password
        guard !pass.isEmpty else { showError("Enter your password"); return }
        let user = NSUserName()
        // Chạy dscl ở nền để KHÔNG khối UI
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = pamCheck(user: user, pass: pass)
            DispatchQueue.main.async {
                if ok { self.unlock() } else { self.showError("Incorrect password. Try again.") }
            }
        }
    }
    func showError(_ msg: String) {
        lockModel.errorText = msg
        lockModel.wrong = true
        lockModel.password = ""
        NSSound.beep()
    }
}

// ============ Kiểm mật khẩu đăng nhập thật qua PAM ============
func pamCheck(user: String, pass: String) -> Bool {
    // gọi /usr/bin/dscl để verify (đơn giản, không cần link libpam)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
    p.arguments = [".", "-authonly", user, pass]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
    do { try p.run(); p.waitUntilExit() } catch { return false }
    return p.terminationStatus == 0
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // TẠM: hiện icon dưới Dock để dễ thấy
appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
