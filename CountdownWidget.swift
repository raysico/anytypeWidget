// CountdownWidget — macOS 悬浮纪念日倒计时小组件（多实例版）
// 数据源：官方 Anytype 客户端本地 API（经 anniversary.py）
// 每个进程 = 一个悬浮窗 = 绑定一个「纪念日」类型对象。
// 同步由官方客户端通过 any-sync 网络完成；标题/日期/颜色可动态刷新。
import Cocoa
import Foundation

let PYTHON = "/usr/bin/python3"

// anniversary.py 查找链（开源可移植，不写死个人绝对路径）：
// 1) 环境变量 WNN_ANNIVERSARY_PY 显式指定
// 2) App 包 Resources 资源（打包时把脚本放进 Resources）
// 3) 可执行文件同目录（仓库根直接编译产物 CountdownWidget-bin）
// 4) 可执行文件上溯三级（.app 放在仓库根时，Contents/MacOS → 仓库根）
// 5) .app 包根目录（脚本随包分发）
// 6) PATH 中的 anniversary（如 ~/bin/anniversary 软链）
// 7) 兜底：当前工作目录下的 anniversary.py
func resolveCLIPath() -> String {
    let fm = FileManager.default
    let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let execDir = execURL.deletingLastPathComponent().path
    var candidates: [String] = []
    if let ov = ProcessInfo.processInfo.environment["WNN_ANNIVERSARY_PY"] { candidates.append(ov) }
    if let r = Bundle.main.path(forResource: "anniversary", ofType: "py") { candidates.append(r) }
    candidates.append(execDir + "/anniversary.py")
    candidates.append(execDir + "/../../../anniversary.py")
    candidates.append(Bundle.main.bundlePath + "/anniversary.py")
    for c in candidates where fm.fileExists(atPath: c) { return c }
    // PATH 查找 anniversary（软链/包装脚本均可，交给 python3 执行）
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "command -v anniversary"]
    let pipe = Pipe(); sh.standardOutput = pipe; sh.standardError = Pipe()
    do {
        try sh.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        let p = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !p.isEmpty && fm.fileExists(atPath: p) { return p }
    } catch {}
    return "anniversary.py"
}
let CLI_PATH = resolveCLIPath()
let CONFIG_DIR = (NSHomeDirectory() as NSString).appendingPathComponent(".whynownote/widgets")
let FETCH_INTERVAL: TimeInterval = 60   // 每 60s 拉一次对象（标题/日期/颜色）
let RECOMPUTE_INTERVAL: TimeInterval = 30 // 每 30s 本地重算数值
let MINI_HEIGHT: CGFloat = 42
let ANNIV_TYPE_KEY = "ji_nian_ri"            // 迷你模式：高度贴合单行文字
let PANEL_TYPE_KEY = "ju_he_mian_ban"        // 聚合面板对象类型
let ASSET_TYPE_KEY = "zi_chan"               // 资产对象类型

// 资产字段 key（与 anniversary.py 保持一致，以类型定义实际 key 为准）
let A_GOU_MAI = "gou_mai_iso"                // 购买日期（ISO）
let A_BAO_XIU = "bao_xiu_iso"                // 保修到期日（ISO）
let A_PRICE = "price"                        // 购买价格（元）
let A_USES = "uses"                          // 使用次数
let A_PERIOD = "period"                      // 计数周期：日/月/年
let A_ASSET_MODE = "asset_mode"              // 使用次数计费 / 使用时长计费

// 聚合面板字段 key（与 anniversary.py 保持一致）
let P_MO_SHI = "mo_shi"
let P_SHAI_XUAN = "shai_xuan_mo_shi"
let P_FEN_LEI = "fen_lei"
let P_BIAO_QIAN = "biao_qian"
let P_XUAN_ZHONG = "xian_shi_de_dui_xiang"
let P_PAI_XU = "pai_xu_mo_shi"
let P_XIAN_ZHI = "xian_zhi_xian_shi_shu_liang"
let DIM_TYPE = "对象类型"
let DIM_MODE = "日期计数默认模式"
let DIM_FEN_LEI = "分类"
let DIM_BIAO_QIAN = "标签"
let SORT_NAME_ASC = "名称升序"
// 迷你行/面板行排版：center=居中；compact=左对齐（按内容）；justify=两端对齐（标题小字左、数值右，标题截断）
let LAYOUT_CENTER = "center"
let LAYOUT_COMPACT = "compact"
let LAYOUT_JUSTIFY = "justify"
// 排序中文选项（Anytype 选择值）↔ 内部归一化 key（共 4 项）
let SORT_KEY_BY_NAME: [String: String] = [
    "名称升序": "name_asc", "名称降序": "name_desc",
    "计数值升序": "count_asc", "计数值降序": "count_desc"
]

enum Mode: String {
    case sinceDay = "since_day"
    case untilDay = "until_day"
    case sinceHour = "since_hour"
    case untilHour = "until_hour"
    case sinceAnniv = "since_anniv"   // 周年计数（已经多少周年）
    case untilRepeat = "until_repeat"
    case birthday = "birthday" // 最近重复日（生日提醒：还有多少天）
    var title: String {
        switch self { case .sinceDay: return "正计日"; case .untilDay: return "倒计日"
                      case .sinceHour: return "正计时"; case .untilHour: return "倒计时"
                      case .sinceAnniv: return "周年计数"; case .untilRepeat: return "最近重复日"
                      case .birthday: return "生日" }
    }
    var unit: String {
        switch self { case .sinceDay, .untilDay, .untilRepeat, .birthday: return "日"
                      case .sinceHour, .untilHour: return "小时"
                      case .sinceAnniv: return "周年" }
    }
    var isSince: Bool {
        switch self { case .sinceDay, .sinceHour, .sinceAnniv: return true
                      case .untilDay, .untilHour, .untilRepeat, .birthday: return false }
    }
    static var all: [Mode] = [.sinceDay, .untilDay, .sinceHour, .untilHour, .sinceAnniv, .untilRepeat, .birthday]
    // 客户端字段里用户可能用的别名（如 "距离最近的重复日"）
    var aliases: [String] {
        switch self { case .untilRepeat: return ["距离最近的重复日"]; default: return [] }
    }
    // 匹配 Anytype 里配置的默认模式文本：先精确匹配标题/别名，再模糊包含兜底
    static func fromText(_ s: String) -> Mode? {
        if let m = all.first(where: { $0.title == s || $0.aliases.contains(s) }) { return m }
        return all.first { s.contains($0.title) }
    }
}

struct Inst: Codable {
    var object_id: String?
    var mode: String
    var mode_manual: Bool?   // [本地]单窗口手动指定过模式；false/nil=跟随对象 mo_shi
    var x: Int
    var y: Int
    var w: Int?
    var h: Int?
    var locked: Bool?
    var pinned: Bool?
    var mini: Bool?
    var agg: Bool?       // 聚合面板
    var agg_type: String? // 聚合面板的对象类型 key
    var agg_title: String? // 聚合面板自定义标题（空则默认「{模式}看板」）
    var agg_sel: [String]? // [旧]聚合面板手动选择，已改为存 Anytype 对象，仅解码兼容
    var agg_sort: String? // [旧]聚合面板排序，已改为存 Anytype 对象，仅解码兼容
    var mode_override: [String: String]? // [本地]面板内某对象的临时显示模式 {对象id: mode raw}，不回写
    var asset_mode: String?              // [本地]资产单窗口计费方式覆盖（使用时长计费/使用次数计费），不回写
    var asset_mode_override: [String: String]? // [本地]面板内资产成员的计费方式覆盖 {对象id: 计费方式}，不回写
    var font_scale: Double?              // [本地]字号缩放（滚轮/双指缩放），默认 1.0
    var panel_layout: String?            // [本地]面板行排版 compact/justify，默认 compact
}

// 子进程运行 CLI，返回 stdout
func runCLI(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: PYTHON)
    p.arguments = [CLI_PATH] + args
    // 脚本位于网盘同步目录：禁止 Python 写 __pycache__——为不同小版本新建 .pyc 会触发
    // 同步扩展的文件创建流程，在同步客户端异常时 open() 永久挂起并卡死整个 GUI
    var env = ProcessInfo.processInfo.environment
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? "" } catch { return "" }
}
func cliJSON(_ args: [String]) -> Any? {
    let s = runCLI(args)
    guard let d = s.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}
func newInstanceId() -> String {
    return "w\(Int(Date().timeIntervalSince1970 * 1000))"   // 毫秒精度，避免同秒复制撞 id
}
func colorFromHex(_ hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespaces).uppercased()
    if h.hasPrefix("#") { h.removeFirst() }
    var r: UInt64 = 0; Scanner(string: h).scanHexInt64(&r)
    if h.count == 6 {
        return NSColor(red: CGFloat((r>>16)&0xff)/255, green: CGFloat((r>>8)&0xff)/255,
                       blue: CGFloat(r&0xff)/255, alpha: 1)
    }
    return .white
}

class DragPanel: NSPanel {
    var dragStart: NSPoint?; var originStart: NSPoint?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var resizing = false
    var lastResize: NSPoint?
    let corner: CGFloat = 24   // 右上角可缩放区域大小

    // 无边框面板默认不能成为 key；滚轮缩放要求窗口处于聚焦状态，故放开
    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        makeKey()   // 点击即聚焦（不抢占其他应用焦点，nonactivatingPanel）
        if event.clickCount >= 2 { return }  // 双击交给热区手势（次数+1），不启动拖拽
        let p = event.locationInWindow
        let f = frame
        if p.x >= f.width - corner && p.y >= f.height - corner {  // 右上角 => 缩放
            resizing = true; lastResize = p; dragStart = nil; originStart = nil
        } else {                                       // 其余区域 => 拖动
            dragStart = p; originStart = f.origin; resizing = false
        }
    }
    // 长按热区触发时，终止可能已经开始的窗口拖拽（长按期间弹窗会吞掉 mouseUp）
    func cancelDrag() {
        resizing = false; lastResize = nil
        dragStart = nil; originStart = nil
    }
    override func mouseDragged(with event: NSEvent) {
        if resizing, let lp = lastResize {
            let p = event.locationInWindow
            onResize?(CGSize(width: p.x - lp.x, height: lp.y - p.y)) // 往下拖=>高度增
            lastResize = p
        } else if let s = dragStart, let o = originStart {
            let c = event.locationInWindow
            setFrameOrigin(NSPoint(x: o.x + c.x - s.x, y: o.y + c.y - s.y))
        }
    }
    override func mouseUp(with event: NSEvent) {
        resizing = false; lastResize = nil
        dragStart = nil; originStart = nil
        onDragEnd?()
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

// 右上角抓手（纯装饰，不拦截事件，交给面板角落缩放）
class GripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.withAlphaComponent(0.55).setStroke()
        ctx.setLineWidth(1.4)
        let w = bounds.width, h = bounds.height
        for i in 0..<3 {
            // 三条斜线由右上角指向窗口中心（左下）
            let x0 = w - 5 - CGFloat(i) * 5
            let y0 = h - 5 - CGFloat(i) * 5
            ctx.move(to: CGPoint(x: x0, y: y0))
            ctx.addLine(to: CGPoint(x: x0 - 5, y: y0 - 5))
            ctx.strokePath()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { return nil } // 不拦截，让事件落到面板
}

// 右下资产图标容器：图片图层在每次布局时铺满（随滚轮缩放自动跟随）；
// 兼作「次数」热区——单击 +1、长按弹窗 -1（仅次数计费可交互）
class AssetIconBoxView: NSView {
    weak var fillLayer: CALayer?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    // 次数计费=true：手型光标/悬停增亮/点击生效；时长计费=false：纯展示，事件交回面板
    var interactive = false {
        didSet {
            guard oldValue != interactive else { return }
            hovering = false
            applyHoverAlpha()
            window?.invalidateCursorRects(for: self)
        }
    }
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let press = NSPressGestureRecognizer(target: self, action: #selector(iconLongPress(_:)))
        press.minimumPressDuration = 0.6
        press.allowableMovement = 10
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let l = fillLayer { l.frame = bounds }
    }

    // 可交互时吞掉 mouseDown：阻止面板把图标上的按下当成窗口拖拽起点
    override func mouseDown(with event: NSEvent) {
        if !interactive { super.mouseDown(with: event) }
    }

    // 单击 +1（长按弹窗时 suppressIncClick 会吞掉抬手时的本次回调）
    override func mouseUp(with event: NSEvent) {
        guard interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -4, dy: -4).contains(p) { onTap?() }
    }

    @objc private func iconLongPress(_ g: NSPressGestureRecognizer) {
        guard g.state == .began, interactive else { return }
        onLongPress?()
    }

    private func applyHoverAlpha() {
        layer?.opacity = (interactive && hovering) ? 1.0 : (interactive ? 0.9 : 1.0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) {
        guard interactive else { return }
        hovering = true; applyHoverAlpha()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false; applyHoverAlpha()
    }
    override func resetCursorRects() {
        if interactive { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

// 根容器：窗口聚焦（key）时，滚轮/双指上下驱动整体字号缩放
class WheelZoomView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        guard window?.isKeyWindow == true, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event); return
        }
        onZoom?(event.scrollingDeltaY)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DragPanel!
    var content: NSView!
    var titleLabel: NSTextField!
    var hintLabel: NSTextField!
    var numberLabel: NSTextField!
    var unitLabel: NSTextField!
    var gripView: GripView!
    var glass: NSVisualEffectView!
    var bgLayer: CALayer!
    var emojiBgLabel: NSTextField!
    var iconFileCache: String?
    var sizeLocked = false
    var objectMenu: NSMenu?

    var instanceId = ""
    var objectId: String?
    var mode: Mode = .sinceDay
    var modeManual = false   // true=用户手动指定过模式，不再跟随对象默认；false=跟随 mo_shi/mo_ren_mo_shi
    var target: Date?
    var color: NSColor = .white
    var lastFetch = Date.distantPast
    var timer: Timer?
    var pinned = true
    var miniMode = false
    var normalW: CGFloat = 0
    var normalH: CGFloat = 0
    var stack: NSStackView!
    var titleWidthCon: NSLayoutConstraint!
    // 资产迷你行：左组（标题/已经/数值/周期）之外的弹性间隔与右组均价标签
    var miniSpacer: NSView!
    var miniAvgLabel: NSTextField!
    // stack 横向定位：纪念日迷你/普通=居中；资产迷你 compact=靠左；justify=靠左且撑满
    var stackCenterXCon: NSLayoutConstraint!
    var stackLeadingCon: NSLayoutConstraint!
    var stackFillWCon: NSLayoutConstraint!
    var lastIcon: Any?
    var currentType: String?
    var prefAppliedObject: String?
    var objectName = ""

    // 聚合面板状态（配置存在 Anytype 面板对象上；本地只存窗口属性与模式覆盖）
    var aggMode = false
    var aggStack: NSStackView!
    var aggHeader: NSTextField?
    var aggItems: [[String: Any]] = []         // 当前行集合（手选优先；排序/limit 之前）
    var aggCandidates: [[String: Any]] = []    // 自动筛选后的候选（勾选菜单用）
    var aggDisplay: [[String: Any]] = []       // 排序+limit 后实际显示
    // (标题, 提示小字, 数值, 周期/单位, 右组均价仅资产行)
    var aggRows: [(NSTextField, NSTextField, NSTextField, NSTextField, NSTextField?)] = []
    // 面板资产行视图 → 对象 id（双击+1 / 长按减一热区）
    var aggRowOidMap: [NSView: String] = [:]
    var panelSort = "name_asc"                 // 归一化排序：name_asc/name_desc/count_asc/count_desc
    var panelLimit = 0
    var panelNameTemplate = ""                 // 面板对象名（支持 {} 变量）
    var panelModeFilterText: String?
    var panelDims: [String] = []
    var panelFenLei: [String] = []
    var panelBiaoQian: [String] = []
    var panelTypeKeys: [String] = []
    var panelProps: [String: Any] = [:]
    var panelFields: [[String: Any]] = []
    var modeOverride: [String: Mode] = [:]     // 本地临时显示模式，不回写
    var fontScale: CGFloat = 1.0               // 字号缩放（聚焦时滚轮/双指调节），本地持久化
    var panelLayout = LAYOUT_COMPACT           // 面板行排版，本地持久化
    var panelLayoutLoaded = false              // 排版是否来自显式选择/配置（否则迷你按类型给默认）
    var dateFmtCache: [String: DateFormatter] = [:]

    // 迷你行生效排版：显式选择优先；无配置时资产默认左对齐、纪念日默认居中
    var effectiveMiniLayout: String {
        if panelLayoutLoaded { return panelLayout }
        return isAsset ? LAYOUT_COMPACT : LAYOUT_CENTER
    }

    // 资产（zi_chan）单对象视图
    var isAsset = false
    var assetContainer: NSView!
    var assetTitleLabel: NSTextField!
    var assetBigNum: NSTextField!
    var assetBigUnit: NSTextField!
    var assetSmallNum: NSTextField!
    var assetSmallUnit: NSTextField!
    var assetPriceLabel: NSTextField!
    var assetAvgLabel: NSTextField!
    var assetIconBox: NSView!                  // 等边矩形容器
    var assetIconLayer: CALayer!               // file 图标：短边填充（aspect-fill）
    var assetEmojiLabel: NSTextField!          // emoji 图标
    // 非迷你资产卡片的栈式布局引用（设计稿 js_21UtLMTGZaI），供滚轮缩放时改间距/尺寸
    var assetOuterStack: NSStackView!
    var assetNumRow: NSStackView!
    var assetWarrantyRow: NSStackView!
    var assetPriceCol: NSStackView!
    var assetPadCons: [NSLayoutConstraint] = []
    var assetIconWCon: NSLayoutConstraint!
    var assetIconHCon: NSLayoutConstraint!
    var assetTitleMaxWCon: NSLayoutConstraint!
    var assetUserWidth = false                 // 用户手动拖宽过卡片（jsdesign：宽可调）；之后宽度只扩不收
    var suppressIncClick = false              // 长按弹窗后吞掉随之而来的 click（避免同时 +1）
    var assetData: [String: Any] = [:]
    var assetModePref: String? = nil         // 单对象窗口的资产计费方式覆盖（使用时长计费/使用次数计费）
    var assetModeOverride: [String: String] = [:]  // 面板内资产成员的计费方式覆盖 {oid: 计费方式}
    var assetIconFileCache: String?            // 已下载图标的 file id
    var assetIconImage: NSImage?               // 普通模式方形图标内存缓存

    var configURL: URL { URL(fileURLWithPath: "\(CONFIG_DIR)/\(instanceId).json") }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 解析启动参数
        let args = CommandLine.arguments
        var initialObject: String?
        var i = 0
        while i < args.count {
            if args[i] == "--instance" && i+1 < args.count { instanceId = args[i+1]; i += 2 }
            else if args[i] == "--object" && i+1 < args.count { initialObject = args[i+1]; i += 2 }
            else if args[i] == "--agg" { aggMode = true; i += 1 }
            else if args[i] == "--agg-type" && i+1 < args.count { aggMode = true; i += 2 } // [旧参数]兼容：面板对象改由 --object 绑定
            else { i += 1 }
        }
        // 默认模式
        mode = .sinceDay
        // 加载该实例配置
        if !instanceId.isEmpty, let d = try? Data(contentsOf: configURL),
           let inst = try? JSONDecoder().decode(Inst.self, from: d) {
            mode = Mode(rawValue: inst.mode) ?? .sinceDay
            modeManual = inst.mode_manual ?? false
            if inst.object_id != nil { objectId = inst.object_id }
            if let l = inst.locked { sizeLocked = l }
            if let p = inst.pinned { pinned = p }
            if let mi = inst.mini { miniMode = mi }
            if let a = inst.agg { aggMode = a }
            // agg_type/agg_title/agg_sel/agg_sort 为旧字段，配置已迁移到 Anytype 面板对象，不再读取
            if let ov = inst.mode_override {
                for (k, v) in ov { if let m = Mode(rawValue: v) { modeOverride[k] = m } }
            }
            if let aov = inst.asset_mode_override { assetModeOverride = aov }
            if let am = inst.asset_mode, !am.isEmpty { assetModePref = am }
            if let fs = inst.font_scale, fs > 0 { fontScale = CGFloat(fs) }
            if let pl = inst.panel_layout { panelLayout = pl; panelLayoutLoaded = true }
            if let x = inst.x as Int?, let y = inst.y as Int?, x != 0 {
                windowPosX = CGFloat(x); windowPosY = CGFloat(y)
            }
            if let w = inst.w, w > 0 { windowSizeW = CGFloat(w); assetUserWidth = true }
            if let h = inst.h, h > 0 { windowSizeH = CGFloat(h) }
        }
        if let o = initialObject { objectId = o }
        if instanceId.isEmpty { instanceId = newInstanceId() }
        saveConfig()   // 持久化启动参数（如新面板窗口的 --object 绑定）

        buildWindow()
        if aggMode {
            if objectId == nil { pickDefaultPanel() } else { fetchAggregate() }
        } else if objectId == nil { pickDefaultObject() } else { fetchAndRender() }
        timer = Timer.scheduledTimer(withTimeInterval: RECOMPUTE_INTERVAL, repeats: true) { _ in
            self.onTick()
        }
    }

    // App 已在运行时再次双击图标 / Finder「打开」：后台组件没有 Dock 窗口可激活，
    // 直接新建一个默认小组件窗口（多窗口=多进程，与「复制窗口」同一启动方式）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let newId = newInstanceId()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--instance", newId]
        try? p.run()
        return true
    }

    var windowPosX: CGFloat = 0
    var windowPosY: CGFloat = 0
    var windowSizeW: CGFloat = 0
    var windowSizeH: CGFloat = 0

    func buildWindow() {
        let panel = DragPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 164),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = pinned ? .floating : .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // 不用窗口矩形阴影，改用圆角容器自绘圆角阴影
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 圆角容器：提供圆角阴影，承载圆角毛玻璃与文字；聚焦时滚轮缩放字号
        let container = WheelZoomView(frame: NSRect(x: 0, y: 0, width: 240, height: 164))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowRadius = 16
        container.layer?.shadowOpacity = 0.35
        container.layer?.shadowOffset = .zero
        container.layer?.borderWidth = 0
        // 图标背景模式的深色底（毛玻璃时被玻璃盖住，无感）
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.9).cgColor

        // 图标背景层（有 file 图标时显示，70% 透明度，圆角裁剪；按短边等比填充 aspect-fill）
        bgLayer = CALayer()
        bgLayer.frame = container.bounds
        bgLayer.cornerRadius = 20
        bgLayer.masksToBounds = true
        bgLayer.contentsGravity = .resizeAspectFill
        bgLayer.opacity = 0.7
        bgLayer.isHidden = true
        bgLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.insertSublayer(bgLayer, at: 0)

        // emoji 背景层（有 emoji 图标时显示，70% 透明度，居中）
        emojiBgLabel = NSTextField(labelWithString: "")
        emojiBgLabel.font = NSFont.systemFont(ofSize: 92)
        emojiBgLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        emojiBgLabel.alignment = .center
        emojiBgLabel.alphaValue = 0.7
        emojiBgLabel.isHidden = true
        emojiBgLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emojiBgLabel)

        // 圆角毛玻璃（模糊桌面背景，裁剪成圆角；随窗口拉伸）
        glass = NSVisualEffectView(frame: container.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        hintLabel.alignment = .center
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        numberLabel = NSTextField(labelWithString: "--")
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)

        unitLabel = NSTextField(labelWithString: "日")
        unitLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        unitLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        unitLabel.alignment = .center
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(numberLabel)
        stack.addArrangedSubview(unitLabel)
        // 资产迷你行专用：弹性间隔 + 右组均价；hidden 时不参与 stack 布局
        miniSpacer = NSView()
        miniSpacer.isHidden = true
        miniAvgLabel = NSTextField(labelWithString: "")
        miniAvgLabel.isHidden = true
        miniAvgLabel.setContentHuggingPriority(.required, for: .horizontal)
        miniAvgLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(miniSpacer)
        stack.addArrangedSubview(miniAvgLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack = stack
        // 资产迷你行：整行热区（双击使用次数+1 / 长按弹窗减一）；非资产迷你时 action 内自行忽略
        installUsesGestures(on: stack, double: #selector(miniRowDoubleTap), long: #selector(miniRowLongPress))

        // 聚合面板行容器（多行列表；单对象模式下隐藏）
        aggStack = NSStackView()
        aggStack.orientation = .vertical
        aggStack.alignment = .leading
        aggStack.spacing = 4
        aggStack.translatesAutoresizingMaskIntoConstraints = false
        aggStack.isHidden = true
        container.addSubview(aggStack)
        NSLayoutConstraint.activate([
            aggStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            aggStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            // 等宽约束：「两端对齐」排版时行可撑满整行；紧凑排版的行按内容宽度，不受影响
            aggStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18)
        ])

        gripView = GripView(frame: NSRect(x: container.bounds.width - 22,
                                          y: container.bounds.height - 24,
                                          width: 20, height: 20))
        gripView.isHidden = sizeLocked
        gripView.autoresizingMask = [.minXMargin, .minYMargin] // 钉住右上角（避开右下图标热区）
        gripView.wantsLayer = true

        buildAssetChrome(container)
        container.addSubview(stack)
        container.addSubview(gripView)
        stackCenterXCon = stack.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        stackLeadingCon = stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)
        stackFillWCon = stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            stackCenterXCon,
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
            stack.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -24),
            emojiBgLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emojiBgLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        titleWidthCon = titleLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24)
        titleWidthCon.isActive = true
        content = container
        panel.contentView = container
        container.onZoom = { [weak self] dy in self?.onWheelZoom(dy) }
        applyFontScale()   // 应用持久化的字号缩放（面板行在 fetch 后重建时同样读 fontScale）
        stack.isHidden = aggMode
        aggStack.isHidden = !aggMode
        panel.onDragEnd = { [weak self] in self?.saveConfig(); self?.writeSizeBack() }
        panel.onResize = { [weak self] delta in self?.applyResize(delta) }
        panel.onRightClick = { [weak self] event in
            guard let self = self, let cv = self.content else { return }
            let menu = NSMenu()
            self.buildMenu(menu)
            NSMenu.popUpContextMenu(menu, with: event, for: cv)
        }
        window = panel

        // 定位（含持久化大小）
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var w = windowSizeW > 0 ? windowSizeW : panel.frame.width
        var h = windowSizeH > 0 ? windowSizeH : panel.frame.height
        if aggMode {
            w = min(max(w, 200), 800); h = 60   // 初始小高度，fetch 后 resizeAggWindow 贴合内容
        } else if miniMode {
            w = min(max(w, 160), 800); h = MINI_HEIGHT
        } else {
            w = min(max(w, 150), 800); h = min(max(h, 150), 600)
        }
        var x = windowPosX != 0 ? windowPosX : screen.maxX - w - 24
        var y = windowPosY != 0 ? windowPosY : screen.maxY - h - 24
        // 屏幕外兜底：持久化位置可能来自已拔掉的外接显示器；若与任一显示器可见区域
        // 的交集小到看不见（或完全不相交），回退到主屏右上角默认位，并写回以便持久化
        let desired = NSRect(x: x, y: y, width: w, height: h)
        let visibleEnough = NSScreen.screens.contains {
            let inter = $0.visibleFrame.intersection(desired)
            return inter.width > 120 && inter.height >= 60
        }
        if !visibleEnough {
            x = screen.maxX - w - 24
            y = screen.maxY - h - 24
            windowPosX = x; windowPosY = y
        }
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        window.orderFrontRegardless()
    }

    // 右键菜单
    func buildMenu(_ m: NSMenu) {
        if aggMode { buildPanelMenu(m) } else { buildSingleMenu(m) }

        // 模式（仅单对象窗口）：纪念日→计数模式（默认=跟随对象）；资产→计费方式（默认=跟随对象默认模式）
        if !aggMode {
            let modeItem = NSMenuItem(title: isAsset ? "计费方式" : "模式", action: nil, keyEquivalent: "")
            m.addItem(modeItem)
            let ms = NSMenu()
            // 第一项始终是「默认（跟随对象）」
            let defTitle = "默认（跟随对象）"
            let def = NSMenuItem(title: defTitle, action: #selector(selectModeFollow(_:)), keyEquivalent: "")
            def.representedObject = ""; def.target = self
            if !modeManual { def.state = .on }
            ms.addItem(def)
            ms.addItem(.separator())
            if isAsset {
                // 资产：使用时长计费 / 使用次数计费
                for txt in ["使用时长计费", "使用次数计费"] {
                    let it = NSMenuItem(title: txt, action: #selector(selectAssetMode(_:)), keyEquivalent: "")
                    it.representedObject = txt; it.target = self
                    if modeManual, assetModePref == txt { it.state = .on }
                    ms.addItem(it)
                }
            } else {
                for mm in Mode.all {
                    let it = NSMenuItem(title: mm.title, action: #selector(selectMode(_:)), keyEquivalent: "")
                    it.representedObject = mm.rawValue; it.target = self
                    if modeManual, mm == mode { it.state = .on }
                    ms.addItem(it)
                }
            }
            m.setSubmenu(ms, for: modeItem)
        }

        m.addItem(NSMenuItem(title: "复制窗口", action: #selector(launchNew(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "新建聚合面板", action: #selector(launchNewPanel(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "马上刷新最新数据", action: #selector(refreshNow(_:)), keyEquivalent: "r"))
        let lockItem = NSMenuItem(title: "锁定大小", action: #selector(toggleLock(_:)), keyEquivalent: "")
        lockItem.state = sizeLocked ? .on : .off
        m.addItem(lockItem)
        let pinItem = NSMenuItem(title: "置顶", action: #selector(togglePin(_:)), keyEquivalent: "")
        pinItem.state = pinned ? .on : .off
        m.addItem(pinItem)
        if !aggMode {
            let miniItem = NSMenuItem(title: "迷你模式", action: #selector(toggleMini(_:)), keyEquivalent: "")
            miniItem.state = miniMode ? .on : .off
            m.addItem(miniItem)
        }
        // 排版切换：面板行（紧凑/两端）；迷你行（居中/左对齐/两端对齐，纪念日与资产一致）
        if aggMode || miniMode {
            let layoutItem = NSMenuItem(title: "排版", action: nil, keyEquivalent: "")
            m.addItem(layoutItem)
            let lm = NSMenu()
            let current = aggMode ? panelLayout : effectiveMiniLayout
            let options: [(String, String)] = aggMode
                ? [(LAYOUT_COMPACT, "自然紧凑（当前）"),
                   (LAYOUT_JUSTIFY, "两端对齐（标题小字在左、数值单位在右，超长截断…）")]
                : [(LAYOUT_CENTER, "居中对齐"),
                   (LAYOUT_COMPACT, "左对齐（自然紧凑）"),
                   (LAYOUT_JUSTIFY, isAsset
                      ? "两端对齐（左组在左、均价在右）"
                      : "两端对齐（标题提示在左、数值单位在右）")]
            for (lk, ll) in options {
                let it = NSMenuItem(title: ll, action: #selector(panelSetLayout(_:)), keyEquivalent: "")
                it.representedObject = lk; it.target = self
                if current == lk { it.state = .on }
                lm.addItem(it)
            }
            m.setSubmenu(lm, for: layoutItem)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "关闭此窗口", action: #selector(quit(_:)), keyEquivalent: "q"))
        for it in m.items { if it.target == nil && it.action != nil { it.target = self } }
    }

    // 单对象窗口菜单：选择对象 + 对象类型 + 修改时间
    func buildSingleMenu(_ m: NSMenu) {
        let objItem = NSMenuItem(title: "选择对象", action: nil, keyEquivalent: "")
        m.addItem(objItem)
        let sub = NSMenu()
        let listType = isAsset ? ASSET_TYPE_KEY : nil
        let objs = cliJSON(["objects"] + (listType.map { [$0] } ?? [])) as? [[String: Any]] ?? []
        if objs.isEmpty {
            sub.addItem(NSMenuItem(title: isAsset ? "(无「资产」对象)" : "(无「纪念日」对象)",
                                   action: nil, keyEquivalent: ""))
        }
        for o in objs {
            let name = o["name"] as? String ?? "?"
            let oid = o["id"] as? String ?? ""
            let it = NSMenuItem(title: name, action: #selector(selectObject(_:)), keyEquivalent: "")
            it.representedObject = oid; it.target = self
            sub.addItem(it)
        }
        m.setSubmenu(sub, for: objItem)

        let typeItem = NSMenuItem(title: "对象类型", action: nil, keyEquivalent: "")
        m.addItem(typeItem)
        let tms = NSMenu()
        let types = cliJSON(["types"]) as? [[String: Any]] ?? []
        if types.isEmpty { tms.addItem(NSMenuItem(title: "(无类型)", action: nil, keyEquivalent: "")) }
        for t in types {
            let key = t["key"] as? String ?? ""
            let name = t["name"] as? String ?? key
            tms.addItem(typeMenuItem(name: name, key: key,
                                     checked: key == currentType,
                                     action: #selector(selectType(_:))))
        }
        m.setSubmenu(tms, for: typeItem)
        if !isAsset {
            m.addItem(NSMenuItem(title: "修改时间…", action: #selector(editTime(_:)), keyEquivalent: ""))
        }
    }

    // 聚合面板窗口菜单（配置全部回写到 Anytype 面板对象；显示模式覆盖仅本地）
    func buildPanelMenu(_ m: NSMenu) {
        // 1. 选择对象：切换绑定的面板 + 勾选本面板显示的成员
        let objItem = NSMenuItem(title: "选择对象", action: nil, keyEquivalent: "")
        m.addItem(objItem)
        let sub = NSMenu()
        let panels = cliJSON(["objects", PANEL_TYPE_KEY]) as? [[String: Any]] ?? []
        if panels.isEmpty { sub.addItem(NSMenuItem(title: "(无聚合面板对象)", action: nil, keyEquivalent: "")) }
        for p in panels {
            let it = NSMenuItem(title: p["name"] as? String ?? "?",
                                action: #selector(selectPanelObject(_:)), keyEquivalent: "")
            it.representedObject = p["id"]; it.target = self
            if p["id"] as? String == objectId { it.state = .on }
            sub.addItem(it)
        }
        sub.addItem(.separator())
        // 勾选改为弹窗复选列表，避免菜单点一次就消失、无法连续多选
        sub.addItem(NSMenuItem(title: "勾选显示对象…", action: #selector(panelPickMembers(_:)), keyEquivalent: ""))
        m.setSubmenu(sub, for: objItem)

        // 2. 成员类型筛选（值）
        let typeItem = NSMenuItem(title: "成员类型", action: nil, keyEquivalent: "")
        m.addItem(typeItem)
        let tms = NSMenu()
        for t in cliJSON(["types"]) as? [[String: Any]] ?? [] {
            guard let key = t["key"] as? String else { continue }
            tms.addItem(typeMenuItem(name: t["name"] as? String ?? key, key: key,
                                     checked: panelTypeKeys.contains(key),
                                     action: #selector(togglePanelType(_:))))
        }
        m.setSubmenu(tms, for: typeItem)

        // 3. 筛选意愿与值
        let filterItem = NSMenuItem(title: "筛选", action: nil, keyEquivalent: "")
        m.addItem(filterItem)
        let fm = NSMenu()
        let typeDim = NSMenuItem(title: "按对象类型筛选", action: #selector(togglePanelDim(_:)), keyEquivalent: "")
        typeDim.representedObject = DIM_TYPE; typeDim.target = self
        typeDim.state = panelDims.contains(DIM_TYPE) ? .on : .off
        fm.addItem(typeDim)
        fm.addItem(configuredSubmenu(title: "分类", dim: DIM_FEN_LEI,
                                     values: unionValues(P_FEN_LEI), selected: panelFenLei,
                                     toggle: #selector(togglePanelFenLei(_:))))
        fm.addItem(configuredSubmenu(title: "标签", dim: DIM_BIAO_QIAN,
                                     values: unionValues(P_BIAO_QIAN), selected: panelBiaoQian,
                                     toggle: #selector(togglePanelBiaoQian(_:))))
        // 日期计数模式：二级菜单选模式值（=启用该维度）
        let modeDimItem = NSMenuItem(title: "按日期计数模式筛选", action: nil, keyEquivalent: "")
        fm.addItem(modeDimItem)
        let mdm = NSMenu()
        let off = NSMenuItem(title: "不按模式筛选", action: #selector(panelSetModeFilter(_:)), keyEquivalent: "")
        off.representedObject = ""; off.target = self
        off.state = panelDims.contains(DIM_MODE) ? .off : .on
        mdm.addItem(off)
        let curMode = panelModeFilterText.flatMap { Mode.fromText($0) }
        for mm in Mode.all {
            let it = NSMenuItem(title: mm.title, action: #selector(panelSetModeFilter(_:)), keyEquivalent: "")
            it.representedObject = mm.rawValue; it.target = self
            if panelDims.contains(DIM_MODE), curMode == mm { it.state = .on }
            mdm.addItem(it)
        }
        fm.setSubmenu(mdm, for: modeDimItem)
        m.setSubmenu(fm, for: filterItem)

        // 4. 对象显示模式（本地覆盖，不回写 Anytype）——按成员类型区分选项：
        //    纪念日→计数模式；资产→计费方式；其它类型→无可用选项
        let ovItem = NSMenuItem(title: "对象显示模式（仅本窗口）", action: nil, keyEquivalent: "")
        m.addItem(ovItem)
        let ovm = NSMenu()
        if aggDisplay.isEmpty { ovm.addItem(NSMenuItem(title: "(无显示中的对象)", action: nil, keyEquivalent: "")) }
        for row in aggDisplay {
            guard let oid = row["id"] as? String else { continue }
            let nm = row["name"] as? String ?? "?"
            let per = NSMenuItem(title: nm, action: nil, keyEquivalent: "")
            ovm.addItem(per)
            let pm = NSMenu()
            if isAssetMember(row) {
                // 资产成员：计费方式
                let def = NSMenuItem(title: "默认（跟随对象）", action: #selector(setLocalAssetOverride(_:)), keyEquivalent: "")
                def.representedObject = ["id": oid, "mode": ""]; def.target = self
                if assetModeOverride[oid] == nil { def.state = .on }
                pm.addItem(def)
                for txt in ["使用时长计费", "使用次数计费"] {
                    let it = NSMenuItem(title: txt, action: #selector(setLocalAssetOverride(_:)), keyEquivalent: "")
                    it.representedObject = ["id": oid, "mode": txt]; it.target = self
                    if assetModeOverride[oid] == txt { it.state = .on }
                    pm.addItem(it)
                }
            } else {
                // 纪念日成员：计数模式
                let def = NSMenuItem(title: "默认（跟随对象）", action: #selector(setLocalModeOverride(_:)), keyEquivalent: "")
                def.representedObject = ["id": oid, "mode": ""]; def.target = self
                if modeOverride[oid] == nil { def.state = .on }
                pm.addItem(def)
                for mm in Mode.all {
                    let it = NSMenuItem(title: mm.title, action: #selector(setLocalModeOverride(_:)), keyEquivalent: "")
                    it.representedObject = ["id": oid, "mode": mm.rawValue]; it.target = self
                    if modeOverride[oid] == mm { it.state = .on }
                    pm.addItem(it)
                }
            }
            ovm.setSubmenu(pm, for: per)
        }
        m.setSubmenu(ovm, for: ovItem)

        // 5. 排序（回写对象）
        let sortItem = NSMenuItem(title: "排序", action: nil, keyEquivalent: "")
        m.addItem(sortItem)
        let sm = NSMenu()
        for (sk, sl) in [("name_asc", "名称升序"), ("name_desc", "名称降序"),
                         ("count_asc", "计数值升序"), ("count_desc", "计数值降序")] {
            let it = NSMenuItem(title: sl, action: #selector(panelSetSort(_:)), keyEquivalent: "")
            it.representedObject = sl; it.target = self
            if panelSort == sk { it.state = .on }
            sm.addItem(it)
        }
        m.setSubmenu(sm, for: sortItem)

        // 排版（自然紧凑/两端对齐）入口在 buildMenu 通用部分，面板与资产迷你共用

        m.addItem(NSMenuItem(title: "显示数量…", action: #selector(panelEditLimit(_:)), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "重命名…", action: #selector(panelRename(_:)), keyEquivalent: ""))
    }

    // 类型菜单项：纪念日/资产/聚合面板可选；其他类型禁选、灰显并备注「（暂不支持）」
    func typeMenuItem(name: String, key: String, checked: Bool, action: Selector) -> NSMenuItem {
        let supported = key == ANNIV_TYPE_KEY || key == PANEL_TYPE_KEY || key == ASSET_TYPE_KEY
        let it = NSMenuItem()
        it.representedObject = key
        if supported {
            it.title = name
            it.action = action; it.target = self
            if checked { it.state = .on }
        } else {
            it.attributedTitle = NSAttributedString(
                string: "\(name)（暂不支持）",
                attributes: [.foregroundColor: NSColor.disabledControlTextColor])
            it.isEnabled = false
        }
        return it
    }

    // 「分类/标签」筛选子菜单：启用开关 + 候选值勾选
    func configuredSubmenu(title: String, dim: String, values: [String],
                           selected: [String], toggle: Selector) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let en = NSMenuItem(title: "启用\(title)筛选", action: #selector(togglePanelDim(_:)), keyEquivalent: "")
        en.representedObject = dim; en.target = self
        en.state = panelDims.contains(dim) ? .on : .off
        menu.addItem(en)
        menu.addItem(.separator())
        if values.isEmpty { menu.addItem(NSMenuItem(title: "(候选对象无\(title))", action: nil, keyEquivalent: "")) }
        for v in values {
            let it = NSMenuItem(title: v, action: toggle, keyEquivalent: "")
            it.representedObject = v; it.target = self
            it.state = selected.contains(v) ? .on : .off
            menu.addItem(it)
        }
        top.submenu = menu
        return top
    }

    func unionValues(_ key: String) -> [String] {
        var set = Set<String>()
        for c in aggCandidates {
            for v in c[key] as? [String] ?? [] { set.insert(v) }
        }
        return set.sorted()
    }

    func panelSelectedIds() -> [String] { panelProps[P_XUAN_ZHONG] as? [String] ?? [] }

    // 回写面板对象属性并立即重拉
    @discardableResult func panelSet(_ updates: [String: Any]) -> Bool {
        guard let oid = objectId,
              let data = try? JSONSerialization.data(withJSONObject: updates),
              let json = String(data: data, encoding: .utf8) else { return false }
        let out = runCLI(["panel-set", oid, json])
        fetchAggregate()
        return out.contains("\"ok\"")
    }

    func toggleDim(_ dim: String) -> [String] {
        var d = panelDims
        if let i = d.firstIndex(of: dim) { d.remove(at: i) } else { d.append(dim) }
        return d
    }

    @objc func selectObject(_ s: NSMenuItem) {
        guard let oid = s.representedObject as? String else { return }
        objectId = oid
        // 切换对象后恢复跟随对象默认
        modeManual = false; assetModePref = nil
        saveConfig()
        fetchAndRender()
    }
    @objc func selectType(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        if key == PANEL_TYPE_KEY {
            // 切到聚合面板形态
            aggMode = true; objectId = nil; prefAppliedObject = nil
            isAsset = false; modeManual = false; assetModePref = nil
            modeOverride = [:]; saveConfig()
            switchPanelChrome(true)
            pickDefaultPanel()
        } else if key == ASSET_TYPE_KEY {
            // 切到资产形态（仍是单对象窗口，不涉及面板）
            aggMode = false; isAsset = false; objectId = nil; prefAppliedObject = nil
            modeOverride = [:]; modeManual = false; assetModePref = nil
            assetData = [:]; assetIconFileCache = nil; assetIconImage = nil
            saveConfig()
            switchSingleChrome(true)
            pickDefaultAsset()
        } else if key == ANNIV_TYPE_KEY {
            aggMode = false; isAsset = false; objectId = nil; prefAppliedObject = nil
            modeOverride = [:]; modeManual = false; assetModePref = nil; saveConfig()
            switchPanelChrome(false)
            assetContainer.isHidden = true
            pickDefaultObject()
        }
    }
    @objc func selectPanelObject(_ s: NSMenuItem) {
        guard let oid = s.representedObject as? String else { return }
        objectId = oid; modeOverride = [:]; saveConfig()
        fetchAggregate()
    }
    // 勾选显示对象：弹窗复选列表，点「保存」一次性提交（全不勾 = 自动筛选结果）
    @objc func panelPickMembers(_ s: NSMenuItem) {
        guard !aggCandidates.isEmpty else { return }
        let preSel = Set(panelSelectedIds())
        let stackBox = NSStackView()
        stackBox.orientation = .vertical; stackBox.alignment = .leading; stackBox.spacing = 4
        var boxes: [(NSButton, String)] = []
        for c in aggCandidates {
            let oid = c["id"] as? String ?? ""
            let cb = NSButton(checkboxWithTitle: c["name"] as? String ?? "?", target: nil, action: nil)
            cb.state = preSel.contains(oid) ? .on : .off
            stackBox.addArrangedSubview(cb)
            boxes.append((cb, oid))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: min(300, CGFloat(boxes.count) * 24 + 8)))
        scroll.documentView = stackBox
        scroll.hasVerticalScroller = true
        stackBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackBox.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 4),
            stackBox.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -4),
            stackBox.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 4)
        ])
        let alert = NSAlert()
        alert.messageText = "勾选显示对象"
        alert.informativeText = "勾选的将固定显示（即使不满足筛选）；全部不勾选则按筛选自动显示"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let sel = boxes.compactMap { $0.0.state == .on ? $0.1 : nil }
            panelSet([P_XUAN_ZHONG: sel])
        }
    }
    @objc func togglePanelType(_ s: NSMenuItem) {
        guard let oid = objectId, let key = s.representedObject as? String else { return }
        var keys = panelTypeKeys
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else { keys.append(key) }
        _ = runCLI(["panel-set-types", oid, keys.joined(separator: ",")])
        fetchAggregate()
    }
    @objc func togglePanelDim(_ s: NSMenuItem) {
        guard let dim = s.representedObject as? String else { return }
        panelSet([P_SHAI_XUAN: toggleDim(dim)])
    }
    @objc func togglePanelFenLei(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String else { return }
        var vals = panelFenLei
        if let i = vals.firstIndex(of: v) { vals.remove(at: i) } else { vals.append(v) }
        var dims = panelDims
        if !vals.isEmpty && !dims.contains(DIM_FEN_LEI) { dims.append(DIM_FEN_LEI) }
        panelSet([P_FEN_LEI: vals, P_SHAI_XUAN: dims])
    }
    @objc func togglePanelBiaoQian(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String else { return }
        var vals = panelBiaoQian
        if let i = vals.firstIndex(of: v) { vals.remove(at: i) } else { vals.append(v) }
        var dims = panelDims
        if !vals.isEmpty && !dims.contains(DIM_BIAO_QIAN) { dims.append(DIM_BIAO_QIAN) }
        panelSet([P_BIAO_QIAN: vals, P_SHAI_XUAN: dims])
    }
    @objc func panelSetModeFilter(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String else { return }
        var dims = panelDims.filter { $0 != DIM_MODE }
        var updates: [String: Any] = [P_SHAI_XUAN: dims]
        if !raw.isEmpty, let mm = Mode(rawValue: raw) {
            dims.append(DIM_MODE)
            updates[P_SHAI_XUAN] = dims
            updates[P_MO_SHI] = [mm.title]
        }
        panelSet(updates)
    }
    @objc func setLocalModeOverride(_ s: NSMenuItem) {
        guard let info = s.representedObject as? [String: String],
              let oid = info["id"] else { return }
        if let raw = info["mode"], !raw.isEmpty, let mm = Mode(rawValue: raw) {
            modeOverride[oid] = mm
        } else {
            modeOverride.removeValue(forKey: oid)
        }
        saveConfig()
        rebuildAggRows(); resizeAggWindow(); renderAggregate(); renderPanelTitle()
    }
    // 面板内资产成员的计费方式本地覆盖（不回写 Anytype）
    @objc func setLocalAssetOverride(_ s: NSMenuItem) {
        guard let info = s.representedObject as? [String: String],
              let oid = info["id"] else { return }
        if let raw = info["mode"], !raw.isEmpty {
            assetModeOverride[oid] = raw
        } else {
            assetModeOverride.removeValue(forKey: oid)
        }
        saveConfig()
        rebuildAggRows(); resizeAggWindow(); renderAggregate(); renderPanelTitle()
    }
    @objc func panelSetSort(_ s: NSMenuItem) {
        guard let text = s.representedObject as? String else { return }
        panelSet([P_PAI_XU: [text]])
    }
    // 排版仅为窗口本地偏好，不回写 Anytype（面板行 / 迷你行共用）
    @objc func panelSetLayout(_ s: NSMenuItem) {
        guard let lk = s.representedObject as? String else { return }
        let current = aggMode ? panelLayout : effectiveMiniLayout
        guard lk != current else { return }
        panelLayout = lk
        panelLayoutLoaded = true
        if aggMode {
            rebuildAggRows(); resizeAggWindow(); renderAggregate(); renderPanelTitle()
        } else if miniMode {
            applyLayout()
            window.layoutIfNeeded()
            if isAsset { renderAsset() } else { render() }
        }
        saveConfig()
    }
    @objc func panelEditLimit(_ s: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "限制显示数量"
        alert.informativeText = "按当前排序只显示前 N 个；填 0 或留空表示不限制"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        tf.stringValue = panelLimit > 0 ? "\(panelLimit)" : ""
        alert.accessoryView = tf
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let n = Int(tf.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            panelSet([P_XIAN_ZHI: max(0, n)])
        }
    }
    @objc func panelRename(_ s: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "重命名面板（即顶部标题）"
        alert.informativeText = """
        支持变量（仅作用于顶部标题，30s 内自动刷新）：
        {行数} 当前显示行数（限制数量截断后）
        {总数} 行集合总数（截断前；手选时=手选数量）
        {模式}/{计算值} 仅恰好显示 1 行时取该行的模式与计数值，否则为空
        {星期} 今天星期几；{日期::yyyy-MM-dd} 按 :: 后格式显示当前日期时间
        {字段中文名} 或 {字段key} 取面板自身字段值，数组以「、」连接
        未识别的 {…} 保留原文
        """
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = panelNameTemplate
        alert.accessoryView = tf
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        // 组件为 accessory 应用：必须激活并把焦点给输入框，否则弹窗无法键入
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { panelSet(["name": name]) }
        }
    }
    @objc func launchNewPanel(_ s: NSMenuItem) {
        // 通过本地 API 新建聚合面板对象，再开窗口绑定它（普通窗口不建对象）
        guard let r = cliJSON(["new-panel"]) as? [String: Any],
              let oid = r["id"] as? String else { return }
        let iid = newInstanceId()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--instance", iid, "--agg", "--object", oid]
        try? p.run()
    }
    @objc func selectMode(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let m = Mode(rawValue: raw) {
            mode = m; modeManual = true; saveConfig()
            // 纪念日模式写回对象 mo_shi
            if !isAsset, let oid = objectId {
                _ = runCLI(["panel-set", oid, jsonString([P_MO_SHI: [m.title]])])
            }
            render()
        }
    }
    // 「默认（跟随对象）」：清除手动覆盖，重新拉取对象默认
    @objc func selectModeFollow(_ s: NSMenuItem) {
        modeManual = false; assetModePref = nil; prefAppliedObject = nil
        saveConfig(); fetchAndRender()
    }
    // 资产：计费方式（使用时长计费/使用次数计费），本地覆盖 + 回写 mo_ren_mo_shi
    @objc func selectAssetMode(_ s: NSMenuItem) {
        guard let txt = s.representedObject as? String, !txt.isEmpty else { return }
        assetModePref = txt; modeManual = true; saveConfig()
        if let oid = objectId {
            _ = runCLI(["panel-set", oid, jsonString(["mo_ren_mo_shi": [txt]])])
        }
        renderAsset()
    }
    func jsonString(_ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
    @objc func editTime(_ s: NSMenuItem) {
        guard let oid = objectId else { return }
        let alert = NSAlert()
        alert.messageText = "修改纪念日日期"
        alert.informativeText = "用日历与时钟选择日期和时间（本地时间）"
        let dp = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 260))
        dp.datePickerStyle = .clockAndCalendar
        dp.datePickerElements = [.yearMonthDay, .hourMinute]
        dp.dateValue = target ?? Date()
        dp.locale = Locale.current
        dp.timeZone = .current
        alert.accessoryView = dp
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = runCLI(["set-date", oid, fmtLocal(dp.dateValue)])
            fetchAndRender()
        }
    }
    func fmtLocal(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: d)
    }
    @objc func launchNew(_ s: NSMenuItem) {
        // 复制窗口：以当前实例配置为模板写入新实例配置（新 id、位置级联偏移），再启动
        saveConfig()
        var cfg: [String: Any] = [:]
        if let d = try? Data(contentsOf: configURL),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            cfg = j
        }
        if let x = cfg["x"] as? Int { cfg["x"] = x + 24 }
        if let y = cfg["y"] as? Int { cfg["y"] = y + 24 }
        guard let d = try? JSONSerialization.data(withJSONObject: cfg) else { return }
        let newId = newInstanceId()
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: "\(CONFIG_DIR)/\(newId).json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--instance", newId]
        try? p.run()
    }
    @objc func toggleLock(_ s: NSMenuItem) {
        sizeLocked.toggle(); gripView.isHidden = sizeLocked; saveConfig()
    }
    @objc func togglePin(_ s: NSMenuItem) {
        pinned.toggle(); window.level = pinned ? .floating : .normal; saveConfig()
    }
    @objc func toggleMini(_ s: NSMenuItem) {
        miniMode.toggle()
        // 进入迷你：记住普通尺寸并收紧为单行；退出迷你：恢复普通尺寸
        syncWindowForMini()
        saveConfig()
        applyLayout()
        // 迷你模式改动回写 Anytype（纪念日/资产对象均有 mi_ni_mo_shi select 字段）
        if let oid = objectId {
            _ = runCLI(["set-mini", oid, miniMode ? "是" : "否"])
        }
        if isAsset {
            // 资产：迷你用横向单行 stack（不展示图标），普通用三行 assetContainer（右侧方形图标）
            switchSingleChrome(true)
            glass.isHidden = false; bgLayer.isHidden = true; emojiBgLabel.isHidden = true
            if miniMode {
                renderAsset()
            } else {
                applyAssetIcon(lastIcon as? [String: Any])
                renderAsset(); resizeAssetWindow()
            }
            return
        }
        // 背景：迷你模式恒用毛玻璃；退出迷你后按最近一次图标恢复
        if miniMode {
            glass.isHidden = false; bgLayer.isHidden = true; emojiBgLabel.isHidden = true
        } else if lastIcon != nil {
            applyIcon(lastIcon)
        } else {
            glass.isHidden = false; bgLayer.isHidden = true; emojiBgLabel.isHidden = true
        }
        render()
    }
    @objc func refreshNow(_ s: NSMenuItem) { if aggMode { fetchAggregate() } else { fetchAndRender() } }
    @objc func quit(_ s: NSMenuItem) { NSApp.terminate(nil) }

    // 右下角拖拽调整大小：字号固定，仅改变窗口大小以显示完整文字
    func applyResize(_ delta: CGSize) {
        guard !sizeLocked else { return }
        // 非迷你资产卡片：jsdesign「宽可调，高固定」——只改宽度，高度始终 184*fontScale
        if isAsset && !miniMode {
            let f = window.frame
            assetContainer?.layoutSubtreeIfNeeded()
            let minW = max(120, ceil(assetContainer?.fittingSize.width ?? 189))
            let w = min(max(f.width + delta.width, minW), 800)
            let h = 184 * fontScale
            window.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: w, height: h), display: true)
            assetUserWidth = true
            saveConfig()
            return
        }
        let f = window.frame
        let left = f.minX, top = f.maxY
        if aggMode {
            // 聚合面板：允许调宽度与高度，高度下限为内容所需
            aggStack.layoutSubtreeIfNeeded()
            let minH = max(20, aggStack.fittingSize.height) + 30
            let w = min(max(200, f.width + delta.width), 800)
            let h = min(max(minH, f.height + delta.height), 600)
            window.setFrame(NSRect(x: left, y: top - h, width: w, height: h), display: true)
            saveConfig()
            return
        }
        var w = f.width + delta.width
        // 普通资产视图需容纳 标题 + 右上「使用次数 +1」按钮，最小宽 230
        let minW: CGFloat = miniMode ? 120 : (isAsset ? 230 : 150)
        let maxW: CGFloat = 800
        w = min(max(minW, w), maxW)
        let minH: CGFloat = (isAsset && !miniMode) ? 210 : 150
        let h = miniMode ? MINI_HEIGHT : min(max(minH, f.height + delta.height), 600)
        window.setFrame(NSRect(x: left, y: top - h, width: w, height: h), display: true)
        saveConfig()
    }

    // 聚焦状态下滚轮/双指上下：整体字号缩放（向上放大、向下缩小，0.7~1.8，步进 0.05）
    func onWheelZoom(_ dy: CGFloat) {
        let next = fontScale * (1 + dy / 100.0)
        let clamped = min(1.8, max(0.7, next))
        let stepped = (clamped * 20).rounded() / 20
        guard stepped != fontScale else { return }
        fontScale = stepped
        applyFontScale()
        if aggMode { resizeAggWindow() }
        saveConfig()
    }

    // 按 fontScale 重设全部字号（单对象 4 个标签 + 资产三行标签 + 面板行）
    func applyFontScale() {
        let s = fontScale
        titleLabel?.font = NSFont.systemFont(ofSize: 30 * s, weight: .bold)
        hintLabel?.font = NSFont.systemFont(ofSize: 12 * s)
        numberLabel?.font = NSFont.monospacedDigitSystemFont(ofSize: 56 * s, weight: .bold)
        unitLabel?.font = NSFont.systemFont(ofSize: 15 * s, weight: .bold)
        if isAsset, assetContainer != nil {
            assetTitleLabel.font = NSFont.systemFont(ofSize: 20 * s, weight: .bold)
            assetBigNum.font = NSFont.monospacedDigitSystemFont(ofSize: 50 * s, weight: .bold)
            assetBigUnit.font = NSFont.systemFont(ofSize: 20 * s, weight: .bold)
            assetSmallNum.font = NSFont.monospacedDigitSystemFont(ofSize: 15 * s, weight: .medium)
            assetSmallUnit.font = NSFont.systemFont(ofSize: 15 * s, weight: .medium)
            assetPriceLabel.font = NSFont.systemFont(ofSize: 14 * s)
            assetAvgLabel.font = NSFont.systemFont(ofSize: 13 * s)
            // 布局度量同步缩放（行距-20/数字间距4/图标56/圆角8）
            assetOuterStack?.spacing = -20 * s
            assetNumRow?.spacing = 4 * s
            assetIconWCon?.constant = 56 * s
            assetIconHCon?.constant = 56 * s
            assetIconBox?.layer?.cornerRadius = 8 * s
            assetTitleMaxWCon?.constant = 260 * s
            let M = 20 * s
            if assetPadCons.count == 4 {
                assetPadCons[0].constant = M; assetPadCons[1].constant = -M
                assetPadCons[2].constant = M; assetPadCons[3].constant = -M
            }
            assetEmojiLabel.font = NSFont.systemFont(ofSize: 36 * s)
            renderAsset()
            if !miniMode { resizeAssetWindow() }
            return
        }
        guard aggMode, aggStack != nil else {
            if !aggMode { render() }
            return
        }
        rebuildAggRows(); renderAggregate(); renderPanelTitle()
    }

    func saveConfig() {
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        // 启动早期（buildWindow 之前）也会调用：窗口尚未创建时保留旧文件里的坐标/尺寸，
        // 绝不能用 .zero 覆盖持久化窗口位置
        var x = 0, y = 0, w = 0, h = 0
        if let f = window?.frame {
            x = Int(f.origin.x); y = Int(f.origin.y)
            w = Int(f.width); h = Int(f.height)
        } else if let d = try? Data(contentsOf: configURL),
                  let prev = try? JSONDecoder().decode(Inst.self, from: d) {
            x = prev.x; y = prev.y; w = prev.w ?? 0; h = prev.h ?? 0
        }
        let inst = Inst(object_id: objectId, mode: mode.rawValue, mode_manual: modeManual,
                        x: x, y: y, w: w, h: h,
                        locked: sizeLocked, pinned: pinned, mini: miniMode,
                        agg: aggMode, agg_type: nil, agg_title: nil, agg_sel: nil, agg_sort: nil,
                        mode_override: aggMode && !modeOverride.isEmpty ? modeOverride.mapValues { $0.rawValue } : nil,
                        asset_mode: isAsset ? assetModePref : nil,
                        asset_mode_override: aggMode && !assetModeOverride.isEmpty ? assetModeOverride : nil,
                        font_scale: Double(fontScale),
                        panel_layout: aggMode ? panelLayout
                                      : miniMode ? effectiveMiniLayout : nil)
        if let d = try? JSONEncoder().encode(inst) {
            try? d.write(to: configURL)
        }
    }

    func pickDefaultObject() {
        let objs = cliJSON(["objects"]) as? [[String: Any]] ?? []
        if let first = objs.first, let oid = first["id"] as? String {
            objectId = oid; saveConfig()
            fetchAndRender()
        } else {
            titleLabel.stringValue = "右键选择对象"
            numberLabel.stringValue = "–"
            unitLabel.stringValue = ""
        }
    }

    // 资产形态：无绑定时默认选第一个资产对象
    func pickDefaultAsset() {
        let objs = cliJSON(["objects", ASSET_TYPE_KEY]) as? [[String: Any]] ?? []
        if let first = objs.first, let oid = first["id"] as? String {
            objectId = oid; saveConfig()
            fetchAndRender()
        } else {
            assetTitleLabel.stringValue = "右键新建资产对象"
            assetBigNum.stringValue = "–"; assetBigUnit.stringValue = ""
        }
    }

    // 面板形态：无绑定时默认选第一个聚合面板对象
    func pickDefaultPanel() {
        let objs = cliJSON(["objects", PANEL_TYPE_KEY]) as? [[String: Any]] ?? []
        if let first = objs.first, let oid = first["id"] as? String {
            objectId = oid; saveConfig()
            fetchAggregate()
        } else {
            panelNameTemplate = "右键新建聚合面板"
            aggItems = []; aggCandidates = []
            rebuildAggRows(); resizeAggWindow(); renderPanelTitle()
        }
    }

    // 单对象视图 ⇄ 面板视图的容器切换
    func switchPanelChrome(_ isPanel: Bool) {
        aggMode = isPanel
        stack.isHidden = isPanel
        aggStack.isHidden = !isPanel
        if isPanel { setAssetChromeInstalled(false) }  // 面板期卸载资产 chrome，避免其最小高约束影响面板
        gripView.isHidden = sizeLocked   // 面板也允许缩放，抓手可见
    }

    func fetchAndRender() {
        guard let oid = objectId else { pickDefaultObject(); return }
        if let obj = cliJSON(["read-object", oid]) as? [String: Any] {
            // 绑定的是聚合面板对象 → 切换为面板形态
            if (obj["type"] as? String) == PANEL_TYPE_KEY {
                if !aggMode { switchPanelChrome(true); saveConfig() }
                fetchAggregate()
                return
            }
            // 绑定的是资产对象 → 资产形态
            if (obj["type"] as? String) == ASSET_TYPE_KEY {
                if aggMode { switchPanelChrome(false) }
                assetData = obj
                objectName = obj["name"] as? String ?? ""
                currentType = ASSET_TYPE_KEY
                color = colorFromHex(obj["color"] as? String ?? "#FFFFFF")
                lastIcon = obj["icon"]
                lastFetch = Date()
                // 先同步对象偏好（可能翻转迷你标志），再按最终形态安装 chrome 与调整窗口，
                // 否则会用旧迷你标志装错视图层级（如迷你启动、对象已取消迷你时卡成占位画面）
                let miniFlipped = applyObjectPrefs(obj)
                if miniFlipped { syncWindowForMini() }
                if !isAsset { switchSingleChrome(true) }
                // 普通模式：毛玻璃 + 右侧方形图标；迷你模式不展示图标，跳过下载
                glass.isHidden = false; bgLayer.isHidden = true; emojiBgLabel.isHidden = true
                if !miniMode { applyAssetIcon(lastIcon as? [String: Any]) }
                applyLayout()
                renderAsset()
                resizeAssetWindow()
                // 迷你：横向布局应用后再贴合一次单行高（首帧可能被初始布局顶高）
                if miniMode { fitMiniHeight() }
                return
            }
            // 纪念日
            if isAsset { switchSingleChrome(false) }
            let name = obj["name"] as? String ?? ""
            let iso = obj["date_iso"] as? String ?? ""
            let hex = obj["color"] as? String ?? "#FFFFFF"
            titleLabel.stringValue = name
            objectName = name
            color = colorFromHex(hex)
            numberLabel.textColor = color
            if let d = parseISO(iso) { target = d } else { target = nil }
            currentType = obj["type"] as? String
            // 对象偏好可能翻转迷你标志：同步窗口尺寸，避免迷你窗口里塞纵向大字布局
            let miniFlipped = applyObjectPrefs(obj)
            if miniFlipped { syncWindowForMini() }
            lastFetch = Date()
            lastIcon = obj["icon"]
            applyLayout()
            applyIcon(lastIcon)
            render()
            // 迷你：buildWindow 时 stack 尚为纵向大字，窗口被内容约束顶高；横向布局应用后贴合单行高
            if miniMode { fitMiniHeight() }
        } else {
            titleLabel.stringValue = "读取失败"
        }
    }

    func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // 对象偏好默认值（Anytype 里配置）：首次绑定某对象时应用 默认模式/迷你模式/资产计费方式
    // 返回迷你标志是否被对象偏好翻转（调用方需据此同步窗口尺寸与 chrome）
    @discardableResult
    func applyObjectPrefs(_ obj: [String: Any]) -> Bool {
        guard let oid = objectId, prefAppliedObject != oid else { return false }
        prefAppliedObject = oid
        var changed = false
        var miniFlipped = false
        // 纪念日：未手动覆盖时才跟随对象 mo_shi；资产：未手动指定时才跟随 mo_ren_mo_shi
        if !modeManual {
            if let arr = obj["mo_shi"] as? [String], let first = arr.first,
               let m = Mode.fromText(first) {
                if mode != m { mode = m; changed = true }
            }
        }
        if !modeManual {
            // 资产：mo_ren_mo_shi 数组 或 read-object 简化输出的 asset_mode 单值
            let am = (obj["mo_ren_mo_shi"] as? [String])?.first ?? (obj["asset_mode"] as? String)
            if let am = am, !am.isEmpty, assetModePref != am { assetModePref = am; changed = true }
        }
        if let arr = obj["mi_ni_mo_shi"] as? [String], let first = arr.first {
            let wantMini = (first == "是")
            if miniMode != wantMini { miniMode = wantMini; changed = true; miniFlipped = true }
        }
        if changed { saveConfig() }
        return miniFlipped
    }

    // 把当前窗口尺寸写回对象「当前宽度/当前高度」（拖拽/缩放结束；面板与资产不写）
    func writeSizeBack() {
        guard !aggMode, !isAsset, let oid = objectId else { return }
        let w = Int(window.frame.width), h = Int(window.frame.height)
        _ = runCLI(["set-size", oid, "\(w)", "\(h)"])
    }

    // 图标背景：有图标（file→图片 70% 透明，emoji→大字 emoji）则去毛玻璃，无图标沿用毛玻璃
    func applyIcon(_ icon: Any?) {
        // 聚合面板 / 迷你模式 / 资产：恒用毛玻璃（资产图标显示在右侧方形内，不走背景）
        if aggMode || miniMode || isAsset {
            glass.isHidden = false
            bgLayer.isHidden = true
            emojiBgLabel.isHidden = true
            return
        }
        guard let d = icon as? [String: Any], let objectId = objectId else {
            glass.isHidden = false
            bgLayer.isHidden = true
            emojiBgLabel.isHidden = true
            return
        }
        let fmt = d["format"] as? String
        if fmt == "file", let fid = d["file"] as? String {
            // 文件 CID 未变则不重下（60s 轮询会反复调用）
            if iconFileCache != fid {
                let tmp = "/tmp/wnn_icon_\(instanceId).img"
                if let r = cliJSON(["icon-image", objectId, tmp]) as? [String: Any],
                   let p = r["path"] as? String, let img = NSImage(contentsOfFile: p) {
                    var rect = NSRect(origin: .zero, size: img.size)
                    if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        bgLayer.contents = cg
                        iconFileCache = fid
                    }
                }
            }
            if bgLayer.contents != nil {
                glass.isHidden = true
                bgLayer.isHidden = false
                emojiBgLabel.isHidden = true
            } else {
                glass.isHidden = false
                bgLayer.isHidden = true
                emojiBgLabel.isHidden = true
            }
        } else if fmt == "emoji", let emo = d["emoji"] as? String {
            emojiBgLabel.stringValue = emo
            glass.isHidden = true
            bgLayer.isHidden = true
            emojiBgLabel.isHidden = false
        } else {
            // named 图标（无本地矢量资源）或其它：沿用毛玻璃
            glass.isHidden = false
            bgLayer.isHidden = true
            emojiBgLabel.isHidden = true
        }
    }

    // 布局与字体：迷你模式=单行、全部同字体同字号、数值加粗用对象HEX色；普通模式=垂直、各自字号
    func applyLayout() {
        if miniMode {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            titleWidthCon.isActive = false
            let mf = NSFont.systemFont(ofSize: 15)
            titleLabel.font = mf
            hintLabel.font = mf
            unitLabel.font = mf
            numberLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
            hintLabel.textColor = NSColor.white.withAlphaComponent(0.6)
            unitLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            titleLabel.lineBreakMode = .byClipping
        } else {
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 6
            titleWidthCon.isActive = true
            titleLabel.font = NSFont.systemFont(ofSize: 30, weight: .bold)
            hintLabel.font = NSFont.systemFont(ofSize: 12)
            unitLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
            numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 56, weight: .bold)
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
            hintLabel.textColor = NSColor.white.withAlphaComponent(0.6)
            unitLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            titleLabel.lineBreakMode = .byTruncatingTail
        }
        numberLabel.textColor = color
        applyMiniLayout()
    }

    // 迷你行排版（纪念日/资产共用三种）：center=居中；compact=左对齐；justify=两端对齐
    // 资产行：左组=购买{标题}已经{计数值}{周期}（组内零间隙），右组=均价
    // 纪念日行 justify：标题提示在左、数值单位在右（spacer 挪到 hint 与 number 之间）
    func applyMiniLayout() {
        let assetMini = isAsset && miniMode
        miniAvgLabel.isHidden = !assetMini
        // 先把自定义间距全部复位为 stack.spacing，避免形态切换后残留
        for v in [titleLabel, hintLabel, numberLabel, unitLabel, miniSpacer] {
            stack.setCustomSpacing(stack.spacing, after: v!)
        }
        guard miniMode else {
            // 普通视图：spacer 复位行尾并隐藏，纵向 stack 保持居中
            moveMiniSpacer(afterHint: false)
            miniSpacer.isHidden = true
            stackCenterXCon.isActive = true
            stackLeadingCon.isActive = false
            stackFillWCon.isActive = false
            return
        }
        let layout = effectiveMiniLayout
        let justify = layout == LAYOUT_JUSTIFY
        // 纪念日两端对齐：spacer 位于 hint 与 number 之间；其余情形位于 unit 与均价之间（行尾）
        moveMiniSpacer(afterHint: !assetMini && justify)
        miniSpacer.isHidden = !justify
        if assetMini {
            // 左组内部紧贴（购买X / 已经 / N / 日 间隙归零）
            stack.setCustomSpacing(0, after: titleLabel)
            stack.setCustomSpacing(0, after: hintLabel)
            stack.setCustomSpacing(0, after: numberLabel)
        }
        switch layout {
        case LAYOUT_CENTER:
            miniSpacer.setContentHuggingPriority(.required, for: .horizontal)
            miniSpacer.setContentCompressionResistancePriority(.required, for: .horizontal)
            stackCenterXCon.isActive = true
            stackLeadingCon.isActive = false
            stackFillWCon.isActive = false
            // 资产居中时左组与均价之间仍留 8pt
            if assetMini { stack.setCustomSpacing(8, after: unitLabel) }
        case LAYOUT_JUSTIFY:
            // 行撑满窗口，spacer 膨胀把右组推到右侧；spacer 两侧间隙归零
            stack.setCustomSpacing(0, after: miniSpacer)
            if assetMini { stack.setCustomSpacing(0, after: unitLabel) }
            else { stack.setCustomSpacing(0, after: hintLabel) }
            miniSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            miniSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            stackCenterXCon.isActive = false
            stackLeadingCon.isActive = true
            stackFillWCon.isActive = true
        default:  // compact 左对齐
            if assetMini { stack.setCustomSpacing(8, after: unitLabel) }
            miniSpacer.setContentHuggingPriority(.required, for: .horizontal)
            miniSpacer.setContentCompressionResistancePriority(.required, for: .horizontal)
            stackCenterXCon.isActive = false
            stackLeadingCon.isActive = true
            stackFillWCon.isActive = false
        }
    }

    // 把弹性 spacer 挪到指定位置：hint 后（纪念日两端对齐）或 unit 后（资产/默认行尾）
    private func moveMiniSpacer(afterHint: Bool) {
        let target: NSView = afterHint ? hintLabel : unitLabel
        guard stack.arrangedSubviews.contains(miniSpacer) else { return }
        stack.removeArrangedSubview(miniSpacer)
        miniSpacer.removeFromSuperview()
        if let ti = stack.arrangedSubviews.firstIndex(of: target) {
            stack.insertArrangedSubview(miniSpacer, at: ti + 1)
        } else {
            stack.addArrangedSubview(miniSpacer)
        }
    }

    // ---- 资产（zi_chan）单对象 ----

    // 非迷你资产视图：栈式自动布局
    // 卡片内边距 20（匹配圆角 20，内容不被裁切），两行垂直排列、行距 -20；
    // 高固定 184*fontScale、宽可调；整体放大缩小由滚轮（fontScale）驱动。
    // 第一行：左列[标题 / 50pt数字+单位(居中,gap4) / 15pt在保]
    // 第二行（高 72）：左下价格两行、右下 56 方形图标（space-between、底对齐）；
    //                  图标即次数热区（单击+1/长按减一，仅次数计费可交互）
    func buildAssetChrome(_ container: NSView) {
        let s = fontScale
        let M: CGFloat = 20 * s   // 卡片四边内边距 20（适应圆角）
        assetContainer = NSView()
        assetContainer.translatesAutoresizingMaskIntoConstraints = false
        assetContainer.isHidden = true
        // 必须先加入 container 建立共同祖先，约束才能合法激活
        container.addSubview(assetContainer)

        // 标题：20pt black（jsdesign Heavy），白90%
        assetTitleLabel = NSTextField(labelWithString: "")
        assetTitleLabel.font = NSFont.systemFont(ofSize: 20 * s, weight: .black)
        assetTitleLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        assetTitleLabel.lineBreakMode = .byTruncatingTail
        assetTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        assetTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 数字行：50pt black（jsdesign Heavy），anytype颜色 + 20pt 单位
        assetBigNum = NSTextField(labelWithString: "--")
        assetBigNum.font = NSFont.monospacedDigitSystemFont(ofSize: 50 * s, weight: .black)
        assetBigNum.setContentHuggingPriority(.required, for: .horizontal)
        assetBigNum.setContentCompressionResistancePriority(.required, for: .horizontal)
        assetBigUnit = NSTextField(labelWithString: "日")
        assetBigUnit.font = NSFont.systemFont(ofSize: 20 * s, weight: .black)
        assetBigUnit.textColor = NSColor.white.withAlphaComponent(0.85)
        assetNumRow = NSStackView(views: [assetBigNum, assetBigUnit])
        assetNumRow.orientation = .horizontal
        assetNumRow.alignment = .centerY  // jsdesign: 左中对齐（垂直居中）
        assetNumRow.spacing = 4 * s
        assetNumRow.translatesAutoresizingMaskIntoConstraints = false
        assetNumRow.setContentHuggingPriority(.required, for: .horizontal)

        // 在保：15pt medium（jsdesign Medium），纯白
        assetSmallNum = NSTextField(labelWithString: "")
        assetSmallNum.font = NSFont.monospacedDigitSystemFont(ofSize: 15 * s, weight: .medium)
        assetSmallNum.textColor = NSColor.white
        assetSmallNum.setContentHuggingPriority(.required, for: .horizontal)
        assetSmallUnit = NSTextField(labelWithString: "")
        assetSmallUnit.font = NSFont.systemFont(ofSize: 15 * s, weight: .medium)
        assetSmallUnit.textColor = NSColor.white
        assetWarrantyRow = NSStackView(views: [assetSmallNum, assetSmallUnit])
        assetWarrantyRow.orientation = .horizontal
        assetWarrantyRow.alignment = .lastBaseline
        assetWarrantyRow.spacing = 0
        assetWarrantyRow.translatesAutoresizingMaskIntoConstraints = false
        assetWarrantyRow.setContentHuggingPriority(.required, for: .horizontal)

        // 左列：标题→数字行→在保，组内 -8 间距（重叠），全部左缘对齐
        let leftCol = NSStackView(views: [assetTitleLabel, assetNumRow, assetWarrantyRow])
        leftCol.orientation = .vertical
        leftCol.alignment = .leading
        leftCol.spacing = -8 * s  // jsdesign: -8 子元素间距
        leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.setContentHuggingPriority(.required, for: .horizontal)
        // 防止超长资产名把窗口撑得过宽
        assetTitleMaxWCon = assetTitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260 * s)
        assetTitleMaxWCon.isActive = true

        // 第一行：仅左列（「+1次」热区已并入第二行右侧图标：单击+1、长按减一）
        let row1 = NSView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.addSubview(leftCol)
        NSLayoutConstraint.activate([
            leftCol.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            leftCol.topAnchor.constraint(equalTo: row1.topAnchor),
            leftCol.bottomAnchor.constraint(equalTo: row1.bottomAnchor),
            leftCol.trailingAnchor.constraint(lessThanOrEqualTo: row1.trailingAnchor)
        ])

        // 第二行左：价格/均价两行，11pt medium（jsdesign Medium），白60%
        assetPriceLabel = NSTextField(labelWithString: "")
        assetPriceLabel.font = NSFont.systemFont(ofSize: 11 * s, weight: .medium)
        assetPriceLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        assetAvgLabel = NSTextField(labelWithString: "")
        assetAvgLabel.font = NSFont.systemFont(ofSize: 11 * s, weight: .medium)
        assetAvgLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        assetPriceCol = NSStackView(views: [assetPriceLabel, assetAvgLabel])
        assetPriceCol.orientation = .vertical
        assetPriceCol.alignment = .leading
        assetPriceCol.spacing = 0
        assetPriceCol.translatesAutoresizingMaskIntoConstraints = false
        assetPriceCol.setContentHuggingPriority(.required, for: .vertical)
        assetPriceCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 第二行右：56 等边图标，圆角 8（file 图 aspect-fill 裁切；emoji 居中）
        assetIconBox = AssetIconBoxView()
        assetIconBox.translatesAutoresizingMaskIntoConstraints = false
        assetIconBox.wantsLayer = true
        assetIconBox.layer?.masksToBounds = true
        assetIconBox.layer?.cornerRadius = 8 * s
        assetIconWCon = assetIconBox.widthAnchor.constraint(equalToConstant: 56 * s)
        assetIconHCon = assetIconBox.heightAnchor.constraint(equalToConstant: 56 * s)
        assetIconWCon.isActive = true; assetIconHCon.isActive = true
        assetIconLayer = CALayer()
        assetIconLayer.contentsGravity = .resizeAspectFill
        assetIconLayer.frame = CGRect(x: 0, y: 0, width: 56 * s, height: 56 * s)
        assetIconBox.layer?.addSublayer(assetIconLayer)
        (assetIconBox as? AssetIconBoxView)?.fillLayer = assetIconLayer
        // 图标即热区：单击次数+1，长按弹窗确认 -1（交互开关由 renderAsset 按计费模式设置）
        (assetIconBox as? AssetIconBoxView)?.onTap = { [weak self] in self?.incUsesTap(nil) }
        (assetIconBox as? AssetIconBoxView)?.onLongPress = { [weak self] in self?.iconLongPress() }
        assetEmojiLabel = NSTextField(labelWithString: "")
        assetEmojiLabel.font = NSFont.systemFont(ofSize: 36 * s)
        assetEmojiLabel.alignment = .center
        assetEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
        assetIconBox.addSubview(assetEmojiLabel)

        // 第二行：普通容器 + 手动约束实现 CSS space-between + align flex-end
        // jsdesign: 自适应宽自动高行，itemSpacing: 72，layoutAlign: STRETCH
        let row2 = NSView()
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.addSubview(assetPriceCol)
        row2.addSubview(assetIconBox)
        NSLayoutConstraint.activate([
            assetPriceCol.leadingAnchor.constraint(equalTo: row2.leadingAnchor),
            assetPriceCol.bottomAnchor.constraint(equalTo: row2.bottomAnchor),
            // 价格列与图标间距 72（jsdesign itemSpacing: 72）
            assetPriceCol.trailingAnchor.constraint(lessThanOrEqualTo: assetIconBox.leadingAnchor,
                                                       constant: -72 * s),
            assetIconBox.trailingAnchor.constraint(equalTo: row2.trailingAnchor),
            assetIconBox.topAnchor.constraint(equalTo: row2.topAnchor),
            assetIconBox.bottomAnchor.constraint(equalTo: row2.bottomAnchor),
            assetEmojiLabel.centerXAnchor.constraint(equalTo: assetIconBox.centerXAnchor),
            assetEmojiLabel.centerYAnchor.constraint(equalTo: assetIconBox.centerYAnchor)
        ])

        // 卡片：两行垂直，行距 -20（重叠）；子行横向拉满
        assetOuterStack = NSStackView(views: [row1, row2])
        assetOuterStack.orientation = .vertical
        assetOuterStack.alignment = .width
        assetOuterStack.spacing = -20 * s  // jsdesign: -20 子元素间距
        assetOuterStack.translatesAutoresizingMaskIntoConstraints = false
        assetContainer.addSubview(assetOuterStack)

        let padL = assetOuterStack.leadingAnchor.constraint(equalTo: assetContainer.leadingAnchor, constant: M)
        let padR = assetOuterStack.trailingAnchor.constraint(equalTo: assetContainer.trailingAnchor, constant: -M)
        let padT = assetOuterStack.topAnchor.constraint(equalTo: assetContainer.topAnchor, constant: M)
        let padB = assetOuterStack.bottomAnchor.constraint(equalTo: assetContainer.bottomAnchor, constant: -M)
        assetPadCons = [padL, padR, padT, padB]
        NSLayoutConstraint.activate([
            assetContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            assetContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            assetContainer.topAnchor.constraint(equalTo: container.topAnchor),
            assetContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            padL, padR, padT, padB
        ])

        // 迷你启动：约束已记录，随即移出层级，避免 42pt 窗口被内部最小高链撑大；
        // 形态切换时由 setAssetChromeInstalled 装回
        if miniMode { assetContainer.removeFromSuperview() }
    }

    // 资产普通 chrome 的装载：迷你时整个移出视图层级——仅 isHidden 仍参与窗口最小高
    // 约束计算，会把 42pt 迷你窗强行撑高；移出后内部四角约束一并失活
    func setAssetChromeInstalled(_ on: Bool) {
        guard let ac = assetContainer, let cv = content else { return }
        if on {
            if ac.superview !== cv { cv.addSubview(ac) }
            ac.isHidden = false
        } else {
            if ac.superview != nil { ac.removeFromSuperview() }
        }
    }

    // 把窗口收到迷你单行高（chrome 卸载后布局不再撑高，手动贴合一次）
    func fitMiniHeight() {
        guard miniMode, let w = window else { return }
        let f = w.frame
        let ww = min(max(f.width, 160), 800)
        w.setFrame(NSRect(x: f.minX, y: f.maxY - MINI_HEIGHT, width: ww, height: MINI_HEIGHT),
                   display: true)
    }

    // 按当前 miniMode 同步窗口尺寸：进入迷你记住普通尺寸并收紧为单行高；
    // 退出迷你恢复普通尺寸（菜单切换与对象偏好翻转共用，避免两条路径行为不一致）
    func syncWindowForMini() {
        guard let w = window else { return }
        let f = w.frame
        if miniMode {
            normalW = f.width; normalH = f.height
            let ww = min(max(f.width, 160), 800)
            w.setFrame(NSRect(x: f.minX, y: f.maxY - MINI_HEIGHT, width: ww, height: MINI_HEIGHT),
                       display: true)
        } else {
            let ww = normalW > 0 ? normalW : max(windowSizeW, 240)
            let hh = normalH > 0 ? normalH : max(windowSizeH, 164)
            let nw = min(max(ww, 150), 800), nh = min(max(hh, 150), 600)
            w.setFrame(NSRect(x: f.minX, y: f.minY, width: nw, height: nh), display: true)
        }
    }

    // 单对象窗口：纪念日视图 ⇄ 资产视图（不涉及聚合面板）
    func switchSingleChrome(_ asset: Bool) {
        isAsset = asset
        if asset {
            aggMode = false
            stack.isHidden = !miniMode   // 资产迷你模式复用横向 stack
            setAssetChromeInstalled(!miniMode)
            if miniMode { fitMiniHeight() }
        } else {
            isAsset = false
            stack.isHidden = miniMode
            setAssetChromeInstalled(false)
        }
        aggStack.isHidden = true
        // 非迷你资产卡片：高固定、宽可调，抓手可见供拖宽
        gripView.isHidden = sizeLocked
    }

    enum AssetPeriod {
        case day, month, year
        var unit: String {
            switch self { case .day: return "日"; case .month: return "月"; case .year: return "年" }
        }
    }

    // 计数周期文本 → 口径（日/月/年/周年；无法识别按日）
    func assetPeriod(_ text: String?) -> AssetPeriod {
        guard let t = text else { return .day }
        if t.contains("年") || t.contains("周年") { return .year }
        if t.contains("月") { return .month }
        return .day
    }

    // 购买日至今的正计数（已满的完整 日/月/年）
    func assetElapsed(from purchase: Date, to now: Date, _ p: AssetPeriod) -> Int {
        let cal = Calendar.current
        switch p {
        case .day:
            return max(0, Int((now.timeIntervalSince(purchase) / 86400).rounded(.down)))
        case .month:
            let c = cal.dateComponents([.month, .day], from: cal.startOfDay(for: purchase),
                                       to: cal.startOfDay(for: now))
            return max(0, (c.month ?? 0) + ((c.day ?? 0) < 0 ? -1 : 0))
        case .year:
            return fullAnniversaries(from: purchase, to: now)
        }
    }

    // 保修倒计数：还剩多少 日/月/年（未满 1 个周期按 1 计；已过期为 0）
    func assetRemaining(until warranty: Date, from now: Date, _ p: AssetPeriod) -> Int {
        let cal = Calendar.current
        let a = cal.startOfDay(for: now); let b = cal.startOfDay(for: warranty)
        if b <= a { return 0 }
        switch p {
        case .day:
            return cal.dateComponents([.day], from: a, to: b).day ?? 0
        case .month:
            let c = cal.dateComponents([.month, .day], from: a, to: b)
            return max(0, (c.month ?? 0) + ((c.day ?? 0) > 0 ? 1 : 0))
        case .year:
            let c = cal.dateComponents([.year, .month, .day], from: a, to: b)
            return max(0, (c.year ?? 0) + ((c.month ?? 0) > 0 || (c.day ?? 0) > 0 ? 1 : 0))
        }
    }

    // 资产视图的全部计算值
    struct AssetCalc {
        var period: AssetPeriod
        var elapsed: Int
        var remaining: Int?
        var priceLine: String      // 粉红行："{购买价}元/{正计数}{周期}" 或 "{购买价}元/{次数}次"
        var avgValue: String       // 平均值："{均价}元/"；除数或价格为 0 时为 "–"
        var avgUnit: String        // 平均单位：按次数计费="次"；按时长计费=计数周期（日/月/年）
        // 平均值+平均单位（普通视图黄色行 / 迷你 / 面板行通用）："129.96元/次"、"12.34元/日"
        var avgText: String {
            return avgValue == "–" ? "–" : avgValue + avgUnit
        }
    }

    // modeOv：面板成员的本地计费方式覆盖；nil=跟随对象默认模式
    func assetCalc(_ d: [String: Any], now: Date = Date(), modeOv: String? = nil) -> AssetCalc? {
        guard let iso = d[A_GOU_MAI] as? String, let purchase = parseISO(iso) else { return nil }
        let p = assetPeriod(d[A_PERIOD] as? String)
        let elapsed = assetElapsed(from: purchase, to: now, p)
        var remaining: Int? = nil
        if let wiso = d[A_BAO_XIU] as? String, let w = parseISO(wiso) {
            // 保修期倒计数始终按「日」，不受计数周期影响
            remaining = assetRemaining(until: w, from: now, .day)
        }
        let modeText = modeOv ?? (d[A_ASSET_MODE] as? String ?? "")
        let byUses = modeText.contains("次数")
        let price = (d[A_PRICE] as? NSNumber)?.doubleValue
            ?? Double((d[A_PRICE] as? String) ?? "") ?? 0
        var denom = 0; var unit = p.unit
        if byUses {
            denom = (d[A_USES] as? NSNumber)?.intValue
                ?? Int((d[A_USES] as? String) ?? "") ?? 0
            unit = "次"
        } else {
            denom = elapsed
        }
        let priceLine = price > 0 ? "\(trimNum(price))元/\(denom)\(unit)" : ""
        // 平均值只含均价格式（"129.96元/"），平均单位按计费方式拼接：次数→"次"，时长→计数周期
        let avgValue = (denom > 0 && price > 0)
            ? "\(String(format: "%.2f", price / Double(denom)))元/" : "–"
        return AssetCalc(period: p, elapsed: elapsed, remaining: remaining,
                         priceLine: priceLine, avgValue: avgValue, avgUnit: unit)
    }

    // 整数价格不带小数点
    func trimNum(_ v: Double) -> String {
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    // 渲染资产普通视图（迷你模式走 renderAssetMini）
    func renderAsset() {
        guard isAsset else { return }
        let name = assetData["name"] as? String ?? "未命名"
        let color = (assetData["color"] as? String).map { colorFromHex($0) } ?? .white
        assetTitleLabel.stringValue = name
        assetBigNum.textColor = color
        // 图标热区仅按使用次数计费时可点（时长计费无次数概念，图标纯展示）
        let byUses = (assetModePref ?? (assetData[A_ASSET_MODE] as? String ?? "")).contains("次数")
        if let iconBox = assetIconBox as? AssetIconBoxView, iconBox.interactive != byUses {
            iconBox.interactive = byUses
        }
        guard let c = assetCalc(assetData, modeOv: assetModePref) else {
            assetBigNum.stringValue = "--"; assetBigUnit.stringValue = "日"
            assetSmallNum.stringValue = ""; assetSmallUnit.stringValue = ""
            assetPriceLabel.stringValue = ""
            assetAvgLabel.stringValue = ""
            if !miniMode { resizeAssetWindow() }
            return
        }
        assetBigNum.stringValue = "\(c.elapsed)"
        assetBigUnit.stringValue = c.period.unit
        if let r = c.remaining {
            if r > 0 {
                assetSmallNum.stringValue = "在保：\(r)"
                assetSmallUnit.stringValue = "日"
                assetSmallNum.textColor = NSColor.white.withAlphaComponent(0.6)
                assetSmallUnit.textColor = NSColor.white.withAlphaComponent(0.6)
            } else {
                assetSmallNum.stringValue = "已过保"
                assetSmallUnit.stringValue = ""
                assetSmallNum.textColor = NSColor.white.withAlphaComponent(0.4)
                assetSmallUnit.textColor = NSColor.white.withAlphaComponent(0.4)
            }
        } else {
            assetSmallNum.stringValue = ""; assetSmallUnit.stringValue = ""
        }
        assetPriceLabel.stringValue = c.priceLine
        assetAvgLabel.stringValue = c.avgText
        if miniMode { renderAssetMini(c) } else { resizeAssetWindow() }
    }

    // 迷你模式（不展示图标/图片）：购买{标题}已经{计数值}{计数周期} {平均值}{平均单位}
    // 平均单位：按使用次数计费="次"；按时长计费=计数周期（日/月/年）
    func renderAssetMini(_ c: AssetCalc? = nil) {
        guard isAsset else { return }
        let name = assetData["name"] as? String ?? "未命名"
        let color = (assetData["color"] as? String).map { colorFromHex($0) } ?? .white
        let calc = c ?? assetCalc(assetData, modeOv: assetModePref)
        let f15 = NSFont.systemFont(ofSize: 15)
        // 已过保的资产标题更暗
        let expired = (calc?.remaining != nil && (calc?.remaining ?? 1) <= 0)
        let titleColor = expired ? NSColor.white.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(0.95)
        titleLabel.attributedStringValue = NSAttributedString(
            string: "购买\(name)", attributes: [.font: f15, .foregroundColor: titleColor])
        hintLabel.attributedStringValue = NSAttributedString(
            string: "已经", attributes: [.font: f15, .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        numberLabel.attributedStringValue = NSAttributedString(
            string: "\(calc?.elapsed ?? 0)",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: color])
        // 左组收尾：计数周期（与计数值同属左组、紧贴）
        unitLabel.attributedStringValue = NSAttributedString(
            string: calc?.period.unit ?? "日",
            attributes: [.font: f15, .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
        // 右组：平均值+平均单位（次数→"次"；时长→计数周期），12pt、更淡；对齐/间距由 stack 分组控制
        miniAvgLabel.attributedStringValue = NSAttributedString(
            string: calc?.avgText ?? "–",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.5)])
    }

    // ---- 使用次数热区：普通视图单击图标+1、长按图标弹窗减一；迷你行/面板行 双击+1、长按减一 ----

    // 调 CLI 增减使用次数；成功回调新次数（已 clamp 到 ≥0）
    @discardableResult
    func bumpUses(oid: String, delta: Int, onNew: @escaping (Int) -> Void) -> Bool {
        guard let r = cliJSON(["inc-uses", oid, "\(delta)"]) as? [String: Any],
              let n = r["uses"] as? Int else { return false }
        onNew(n)
        return true
    }

    // 把归一化数据（assetData 或面板行 item）中的使用次数替换为新值
    private func patchUses(_ dict: inout [String: Any], _ n: Int) {
        dict[A_USES] = n
    }

    // 单对象资产：次数回写后的本地刷新
    private func applySingleUses(_ n: Int) {
        patchUses(&assetData, n)
        renderAsset()
        fetchAndRender()   // 30s 周期外的后台校正
    }

    // 单对象资产：弹窗确认后减一
    private func promptSingleDecrement(oid: String, name: String) {
        confirmDecrement(name: name) { [weak self] in
            self?.bumpUses(oid: oid, delta: -1) { n in
                self?.applySingleUses(n)
            }
        }
        // 弹窗结束后短暂保留抑制，吞掉长按抬手时可能补发的按钮 click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.suppressIncClick = false
        }
    }

    @objc func incUsesTap(_ sender: Any?) {
        // 长按手势已触发减一弹窗：忽略随之而来的按钮 click
        if suppressIncClick { suppressIncClick = false; return }
        guard let oid = objectId else { return }
        bumpUses(oid: oid, delta: +1) { [weak self] n in
            self?.applySingleUses(n)
        }
    }

    // 普通视图：长按资产图标 → 弹窗询问是否减一
    func iconLongPress() {
        guard !miniMode, let oid = objectId else { return }
        window.cancelDrag()
        suppressIncClick = true
        let name = assetData["name"] as? String ?? "该资产"
        promptSingleDecrement(oid: oid, name: name)
    }

    @objc func miniRowDoubleTap(_ g: NSClickGestureRecognizer) {
        guard isAsset, miniMode, let oid = objectId else { return }
        bumpUses(oid: oid, delta: +1) { [weak self] n in
            guard let self = self else { return }
            self.patchUses(&self.assetData, n)
            self.renderAsset()
            self.fetchAndRender()
        }
    }

    @objc func miniRowLongPress(_ g: NSPressGestureRecognizer) {
        guard g.state == .began, isAsset, miniMode, let oid = objectId else { return }
        window.cancelDrag()
        let name = assetData["name"] as? String ?? "该资产"
        promptSingleDecrement(oid: oid, name: name)
    }

    @objc func aggRowDoubleTap(_ g: NSClickGestureRecognizer) {
        guard let row = g.view, let oid = aggRowOidMap[row] else { return }
        bumpAggUses(oid: oid, delta: +1)
    }

    @objc func aggRowLongPress(_ g: NSPressGestureRecognizer) {
        guard g.state == .began, let row = g.view, let oid = aggRowOidMap[row] else { return }
        window.cancelDrag()
        let name = aggDisplay.first(where: { ($0["id"] as? String) == oid })?["name"] as? String
            ?? "该资产"
        confirmDecrement(name: name) { [weak self] in
            self?.bumpAggUses(oid: oid, delta: -1)
        }
    }

    private func bumpAggUses(oid: String, delta: Int) {
        bumpUses(oid: oid, delta: delta) { [weak self] n in
            guard let self = self,
                  let i = self.aggDisplay.firstIndex(where: { ($0["id"] as? String) == oid }) else { return }
            self.aggDisplay[i][A_USES] = n
            self.renderAggregate()
            self.fetchAggregate()   // 后台校正排序/均值
        }
    }

    private func confirmDecrement(name: String, doDecrement: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "「\(name)」使用次数减一？"
        alert.informativeText = "用于撤销误触的 +1；次数不会低于 0。"
        alert.addButton(withTitle: "减一")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { doDecrement() }
    }

    // 给热区视图挂 双击+1 / 长按减一
    func installUsesGestures(on v: NSView, double: Selector, long: Selector) {
        let dbl = NSClickGestureRecognizer(target: self, action: double)
        dbl.numberOfClicksRequired = 2
        let press = NSPressGestureRecognizer(target: self, action: long)
        press.minimumPressDuration = 0.6
        press.allowableMovement = 10
        v.addGestureRecognizer(dbl)
        v.addGestureRecognizer(press)
    }

    // 资产图标：仅普通模式填入右侧方形（file→短边填充；emoji→方形内居中）；迷你/面板行不展示图标
    func applyAssetIcon(_ icon: [String: Any]?) {
        assetIconLayer.contents = nil; assetEmojiLabel.stringValue = ""
        guard let d = icon else { assetIconImage = nil; assetIconFileCache = nil; return }
        let fmt = d["format"] as? String
        if fmt == "file", let fid = d["file"] as? String {
            // 图标 file id 未变且内存图存在 → 直接复用；否则重新下载
            if assetIconFileCache != fid || assetIconImage == nil {
                let tmp = "/tmp/wnn_asset_icon_\(instanceId).img"
                if let r = cliJSON(["icon-image", objectId ?? "", tmp]) as? [String: Any],
                   let p = r["path"] as? String, let img = NSImage(contentsOfFile: p) {
                    assetIconImage = img
                    assetIconFileCache = fid
                }
            }
            if let img = assetIconImage {
                // 图层固定铺满 72 方框（autoresizingMask 跟随缩放），aspect-fill 中心裁切
                var rect = NSRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    assetIconLayer.contents = cg
                }
            }
        } else if fmt == "emoji", let emo = d["emoji"] as? String {
            assetEmojiLabel.stringValue = emo
            assetIconImage = nil; assetIconFileCache = nil
        } else {
            assetIconImage = nil; assetIconFileCache = nil
        }
    }

    // 资产窗口：高度固定 184*fontScale；宽度贴合内容，或保留用户手调宽度（左上角不动）
    func resizeAssetWindow() {
        guard isAsset, assetContainer != nil else { return }
        if miniMode { return }   // 迷你行高度由 MINI_HEIGHT 逻辑管理
        let f = window.frame
        assetContainer.layoutSubtreeIfNeeded()
        let fit = assetContainer.fittingSize
        // 卡片「宽可调，高固定」：高度恒为 184*fontScale（内容 144 + 上下内边距各 20）
        let h = 184 * fontScale
        let fitW = max(120, ceil(fit.width))
        // 未手调过宽度 → 贴合内容；手调/配置恢复过 → 保留用户宽度，仅在内容更宽时扩宽
        let w = assetUserWidth ? max(f.width, fitW) : fitW
        if abs(w - f.width) > 0.5 || abs(h - f.height) > 0.5 {
            window.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: w, height: h), display: true)
        }
    }

    // ---- 聚合面板 ----
    func fetchAggregate() {
        guard let oid = objectId else { pickDefaultPanel(); return }
        guard let d = cliJSON(["panel-data", oid]) as? [String: Any] else {
            panelNameTemplate = "面板读取失败"
            aggItems = []; aggCandidates = []
            rebuildAggRows(); resizeAggWindow(); renderPanelTitle()
            return
        }
        // —— 面板配置（字段 key 以聚合面板类型定义实际 key 为准）——
        panelProps = d["props"] as? [String: Any] ?? [:]
        panelDims = d["dims"] as? [String] ?? []
        panelTypeKeys = d["type_keys"] as? [String] ?? []
        panelFenLei = d["fen_lei"] as? [String] ?? []
        panelBiaoQian = d["biao_qian"] as? [String] ?? []
        panelFields = d["fields"] as? [[String: Any]] ?? []
        panelModeFilterText = d["mode_filter_text"] as? String
        if let nm = d["name"] as? String, !nm.isEmpty { panelNameTemplate = nm }
        panelLimit = (d["limit"] as? NSNumber)?.intValue ?? 0
        // 排序：未识别的非空值回写「名称升序」（panelSet 内会重拉，本次直接返回）
        if let st = d["sort_text"] as? String, !st.isEmpty, SORT_KEY_BY_NAME[st] == nil {
            panelSet([P_PAI_XU: [SORT_NAME_ASC]])
            return
        }
        panelSort = (d["sort_text"] as? String).flatMap { SORT_KEY_BY_NAME[$0] } ?? "name_asc"

        // —— 行数据：在边界完成归一化（date_iso→Date、HEX→NSColor、名称兜底）——
        aggCandidates = (d["candidates"] as? [[String: Any]] ?? []).map(normalizeMember)
        let selected = d["selected"] as? [String] ?? []
        // 手选最高优先且互斥：非空只显示手选对象；为空显示自动筛选结果
        aggItems = selected.isEmpty
            ? aggCandidates
            : (d["selected_rows"] as? [[String: Any]] ?? []).map(normalizeMember)

        lastFetch = Date()
        rebuildAggRows()
        resizeAggWindow()
        renderAggregate()
        renderPanelTitle()
    }

    // 成员行归一化：纪念日/资产各自日期解析（gou_mai→date 供排序）、HEX→NSColor、名称兜底
    func normalizeMember(_ m: [String: Any]) -> [String: Any] {
        var x = m
        if (x["name"] as? String) == nil { x["name"] = "未命名" }
        if let iso = m["date_iso"] as? String, let dt = parseISO(iso) { x["date"] = dt }
        if let giso = m[A_GOU_MAI] as? String, let dt = parseISO(giso) { x["gou_mai_date"] = dt }
        x["color"] = (m["color"] as? String).map { colorFromHex($0) } ?? NSColor.white
        return x
    }

    // 纪念日成员
    func isAnnivMember(_ item: [String: Any]) -> Bool {
        return (item["type"] as? String) == ANNIV_TYPE_KEY && item["date"] is Date
    }

    // 资产成员
    func isAssetMember(_ item: [String: Any]) -> Bool {
        return (item["type"] as? String) == ASSET_TYPE_KEY && item["gou_mai_date"] is Date
    }

    // 某行实际计数模式：本地窗口覆盖（不回写 Anytype）> 对象自身 mo_shi > 兜底正计日
    func effectiveMode(for item: [String: Any]) -> Mode {
        if let oid = item["id"] as? String, let m = modeOverride[oid] { return m }
        if let t = item["mo_shi"] as? String, let m = Mode.fromText(t) { return m }
        return .sinceDay
    }

    // 计算某行的计数值（用于显示与排序）：纪念日按其模式；资产=购买正计数；其它无意义返回 0
    func aggCount(_ item: [String: Any], now: Date) -> Int {
        if isAssetMember(item) {
            return assetCalc(item, now: now)?.elapsed ?? 0
        }
        guard isAnnivMember(item), let d = item["date"] as? Date else { return 0 }
        switch effectiveMode(for: item) {
        case .sinceDay: return max(0, Int((now.timeIntervalSince(d)/86400).rounded(.down)))
        case .untilDay: return d > now ? Int(((d.timeIntervalSince(now)/86400).rounded(.up))) : 0
        case .sinceHour: return max(0, Int((now.timeIntervalSince(d)/3600).rounded(.down)))
        case .untilHour: return d > now ? Int(((d.timeIntervalSince(now)/3600).rounded(.up))) : 0
        case .sinceAnniv: return fullAnniversaries(from: d, to: now)
        case .untilRepeat, .birthday: return daysToNextRepeat(of: d, now: now)
        }
    }

    func rebuildAggRows() {
        for v in aggStack.arrangedSubviews { aggStack.removeArrangedSubview(v); v.removeFromSuperview() }
        aggRows.removeAll()
        aggRowOidMap.removeAll()
        let s = fontScale
        let justify = panelLayout == LAYOUT_JUSTIFY
        // 顶部标题（文本由 renderPanelTitle 渲染；{} 变量只作用于此标题，行标题由成员对象决定）
        let header = NSTextField(labelWithString: "")
        header.font = NSFont.systemFont(ofSize: 18 * s, weight: .bold)
        header.textColor = NSColor.white.withAlphaComponent(0.95)
        header.lineBreakMode = .byTruncatingTail
        aggStack.addArrangedSubview(header)
        aggHeader = header
        let gap = NSView()
        aggStack.addArrangedSubview(gap)
        NSLayoutConstraint.activate([gap.heightAnchor.constraint(equalToConstant: 10)])

        // 排序（手选互斥已在拉取时决定，这里只排当前行集合）
        var disp = aggItems
        let now = Date()
        switch panelSort {
        case "name_asc":
            disp.sort { ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending }
        case "name_desc":
            disp.sort { ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedDescending }
        case "count_asc":
            disp.sort { aggCount($0, now: now) < aggCount($1, now: now) }
        case "count_desc":
            disp.sort { aggCount($0, now: now) > aggCount($1, now: now) }
        default: break
        }
        // 限制显示数量：排序后取前 N（0 = 不限制）
        if panelLimit > 0 { disp = Array(disp.prefix(panelLimit)) }
        aggDisplay = disp

        if aggDisplay.isEmpty {
            let empty = NSTextField(labelWithString: "（暂无显示对象）")
            empty.font = NSFont.systemFont(ofSize: 13 * s)
            empty.textColor = NSColor.white.withAlphaComponent(0.55)
            aggStack.addArrangedSubview(empty)
            return
        }
        for item in aggDisplay {
            let name = item["name"] as? String ?? "未命名"
            let color = item["color"] as? NSColor ?? .white
            let tl = NSTextField(labelWithString: name)
            // 两种排版字体一致（14pt 粗体）；两端对齐只改变分组布局，不改字体字号与颜色
            tl.font = NSFont.systemFont(ofSize: 14 * s, weight: .bold)
            tl.textColor = NSColor.white.withAlphaComponent(0.95)
            tl.lineBreakMode = .byTruncatingTail   // 宽度不足截断并显示「…」
            tl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tl.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let ht = NSTextField(labelWithString: "")
            ht.font = NSFont.systemFont(ofSize: 11 * s)
            ht.textColor = NSColor.white.withAlphaComponent(0.6)
            let num = NSTextField(labelWithString: "--")
            num.font = NSFont.monospacedDigitSystemFont(ofSize: 16 * s, weight: .bold)
            num.textColor = color
            num.setContentCompressionResistancePriority(.required, for: .horizontal)
            num.setContentHuggingPriority(.required, for: .horizontal)
            let un = NSTextField(labelWithString: "")
            un.font = NSFont.systemFont(ofSize: 12 * s, weight: .bold)
            un.textColor = NSColor.white.withAlphaComponent(0.7)
            un.setContentHuggingPriority(.required, for: .horizontal)
            // 资产行分组同迷你行：左组=购买{标题}已经{计数值}{周期}（组内零间隙），右组=均价
            let isAssetRow = isAssetMember(item)
            let avg: NSTextField?
            let left = NSStackView(); left.orientation = .horizontal; left.alignment = .firstBaseline
            let right = NSStackView(); right.orientation = .horizontal; right.alignment = .firstBaseline
            if isAssetRow {
                avg = NSTextField(labelWithString: "")
                avg?.font = NSFont.systemFont(ofSize: 12 * s)
                avg?.textColor = NSColor.white.withAlphaComponent(0.5)
                avg?.setContentHuggingPriority(.required, for: .horizontal)
                avg?.setContentCompressionResistancePriority(.required, for: .horizontal)
                left.spacing = 0
                left.addArrangedSubview(tl); left.addArrangedSubview(ht)
                left.addArrangedSubview(num); left.addArrangedSubview(un)
                right.spacing = 0
                right.addArrangedSubview(avg!)
            } else {
                avg = nil
                left.spacing = 6
                left.addArrangedSubview(tl); left.addArrangedSubview(ht)
                right.spacing = 4
                right.addArrangedSubview(num); right.addArrangedSubview(un)
            }
            // 标题先压缩，数值单位/均价保持完整靠右
            left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            left.setContentHuggingPriority(.defaultLow, for: .horizontal)
            right.setContentCompressionResistancePriority(.required, for: .horizontal)
            right.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let flex = NSStackView(); flex.orientation = .horizontal; flex.alignment = .firstBaseline; flex.spacing = 10
            flex.addArrangedSubview(left); flex.addArrangedSubview(spacer); flex.addArrangedSubview(right)
            aggStack.addArrangedSubview(flex)
            // 两端对齐：行撑满面板宽度，左组在左、右组在右；紧凑：行按内容自然宽度（spacer 收为 0）
            if justify {
                flex.widthAnchor.constraint(equalTo: aggStack.widthAnchor).isActive = true
            }
            // 资产行整行热区：双击次数+1 / 长按弹窗减一
            if isAssetRow, let oid = item["id"] as? String {
                aggRowOidMap[flex] = oid
                installUsesGestures(on: flex, double: #selector(aggRowDoubleTap), long: #selector(aggRowLongPress))
            }
            aggRows.append((tl, ht, num, un, avg))
        }
    }

    // 顶部标题模板：{行数} {总数} {模式} {计算值}（后两者仅恰好显示一行时取值），
    // 以及 {字段中文名/key}（按面板类型字段定义匹配面板对象自身属性；未识别保留原文）
    func renderPanelTitle() {
        guard let header = aggHeader else { return }
        var modeText = "", valueText = ""
        if aggDisplay.count == 1, let item = aggDisplay.first {
            modeText = effectiveMode(for: item).title
            valueText = isAnnivMember(item) ? "\(aggCount(item, now: Date()))" : "–"
        }
        let builtins: [String: String] = [
            "行数": "\(aggDisplay.count)",
            "总数": "\(aggItems.count)",
            "模式": modeText,
            "计算值": valueText
        ]
        header.stringValue = renderPanelTemplate(panelNameTemplate, builtins: builtins)
    }

    // 逐段替换 {token}：内置变量 → 面板字段（name/key 匹配）→ 未识别保留原文
    func renderPanelTemplate(_ text: String, builtins: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{([^{}]+)\\}") else { return text }
        let src = text as NSString
        var out = ""
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: src.length)) {
            if m.range.location > pos { out += src.substring(with: NSRange(location: pos, length: m.range.location - pos)) }
            let token = src.substring(with: m.range(at: 1))
            if let b = builtins[token] {
                out += b
            } else if token == "星期" {
                out += weekdayText(Date())
            } else if token.hasPrefix("日期::") {
                let pat = String(token.dropFirst("日期::".count))
                if let t = formatDate(pat, date: Date()) { out += t } else { out += src.substring(with: m.range) }
            } else if let key = panelFieldKey(token), let v = panelPropText(key) {
                out += v
            } else {
                out += src.substring(with: m.range)
            }
            pos = m.range.location + m.range.length
        }
        if pos < src.length { out += src.substring(with: NSRange(location: pos, length: src.length - pos)) }
        return out
    }

    // 模板 token → 字段 key：字段中文名或 key 命中即可（防日后改名）
    func panelFieldKey(_ token: String) -> String? {
        for f in panelFields {
            if let key = f["key"] as? String {
                if key == token || (f["name"] as? String) == token { return key }
            }
        }
        return nil
    }

    // 面板对象属性 → 可显示文本（数组以「、」连接）
    func panelPropText(_ key: String) -> String? {
        guard let v = panelProps[key] else { return nil }
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        case let arr as [Any]:
            let parts = arr.map { ($0 as? String) ?? "\($0)" }
            return parts.isEmpty ? nil : parts.joined(separator: "、")
        default: return "\(v)"
        }
    }

    // 今天星期几 → 「星期一」…「星期日」
    func weekdayText(_ date: Date) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let w = Calendar(identifier: .gregorian).component(.weekday, from: date)  // 1=周日
        return "星期\(names[(w - 1 + 7) % 7])"
    }

    // 按用户给定的格式串格式化日期（ISO 8601 风格，如 yyyy-MM-dd HH:mm）；非法格式返回 nil
    func formatDate(_ pattern: String, date: Date) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        if dateFmtCache[p] == nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = p
            dateFmtCache[p] = f
        }
        return dateFmtCache[p]?.string(from: date)
    }

    func resizeAggWindow() {
        let f = window.frame
        // 用 fittingSize（内容自然高度）定最小高度，避免底部留白
        aggStack.layoutSubtreeIfNeeded()
        let contentH = max(20, aggStack.fittingSize.height)
        let minH = contentH + 30   // 内容 + 上下各约 15px 边距
        // 启动/刷新贴合内容；用户手动拉高时保留（max），不被弹回
        let h = max(f.height, minH)
        let w = min(max(f.width, 200), 800)
        let top = f.maxY
        window.setFrame(NSRect(x: f.minX, y: top - h, width: w, height: h), display: true)
        saveConfig()
    }

    func renderAggregate() {
        let now = Date()
        for (i, row) in aggRows.enumerated() {
            guard i < aggDisplay.count else { continue }
            let item = aggDisplay[i]
            let name = item["name"] as? String ?? "未命名"
            let (t, h, n, u, avg) = row
            // 资产成员（不展示图标/图片）：左组「购买{标题}已经{计数值}{周期}」贴左，右组均价
            if isAssetMember(item) {
                // 已过保的资产标题更暗
                let mOid = item["id"] as? String ?? ""
                let mCalc = assetCalc(item, now: now, modeOv: assetModeOverride[mOid])
                let titleAttrs: [NSAttributedString.Key: Any]
                if let c = mCalc, c.remaining != nil, (c.remaining ?? 1) <= 0 {
                    titleAttrs = [.foregroundColor: NSColor.white.withAlphaComponent(0.4)]
                } else { titleAttrs = [:] }
                t.attributedStringValue = NSAttributedString(string: "购买\(name)", attributes: titleAttrs)
                h.stringValue = "已经"
                if let c = mCalc {
                    n.stringValue = "\(c.elapsed)"
                    u.stringValue = c.period.unit
                    avg?.stringValue = c.avgText
                } else {
                    n.stringValue = "–"; u.stringValue = ""; avg?.stringValue = ""
                }
                continue
            }
            // 其它非纪念日成员：计数逻辑尚未开发，数值显示「–」，无提示与单位
            guard isAnnivMember(item), let d = item["date"] as? Date else {
                t.stringValue = name
                h.stringValue = ""
                n.stringValue = "–"
                u.stringValue = ""
                continue
            }
            let mm = effectiveMode(for: item)
            if mm == .birthday {
                let anniv = fullAnniversaries(from: d, to: now)
                let days = daysToNextRepeat(of: d, now: now)
                var nm = name
                if nm.hasSuffix("生日") { nm = String(nm.dropLast(2)) }
                t.stringValue = "离\(nm)的\(anniv)岁生日"
                h.stringValue = "还有"
                n.stringValue = "\(days)"
                u.stringValue = "日"
            } else {
                t.stringValue = name
                h.stringValue = mm.isSince ? "已经" : "还有"
                u.stringValue = mm.unit
                n.stringValue = "\(aggCount(item, now: now))"
            }
        }
    }

    func onTick() {
        let stale = Date().timeIntervalSince(lastFetch) > FETCH_INTERVAL
        if aggMode {
            // 30s 重算：行数/计算值类标题变量也要刷新
            if stale { fetchAggregate() } else { renderAggregate(); renderPanelTitle() }
        }
        else {
            if stale { fetchAndRender() }
            else if isAsset { renderAsset() }
            else { render() }
        }
    }

    func render() {
        let now = Date()
        hintLabel.stringValue = mode.isSince ? "（已经）" : "（还有）"
        guard let t = target else {
            numberLabel.stringValue = "--"
            unitLabel.stringValue = mode.unit
            return
        }
        if mode == .birthday {
            let anniv = fullAnniversaries(from: t, to: now)
            let days = daysToNextRepeat(of: t, now: now)
            var nm = objectName
            if nm.hasSuffix("生日") { nm = String(nm.dropLast(2)) } // 标题里屏蔽"生日"两字
            titleLabel.stringValue = "离\(nm)的\(anniv)岁生日"
            hintLabel.stringValue = "（还有）"
            numberLabel.stringValue = "\(days)"
            unitLabel.stringValue = "日"
            return
        }
        var num = 0
        switch mode {
        case .sinceDay:
            num = max(0, Int((now.timeIntervalSince(t) / 86400).rounded(.down)))
        case .untilDay:
            num = t > now ? Int(((t.timeIntervalSince(now) / 86400).rounded(.up))) : 0
        case .sinceHour:
            num = max(0, Int((now.timeIntervalSince(t) / 3600).rounded(.down)))
        case .untilHour:
            num = t > now ? Int(((t.timeIntervalSince(now) / 3600).rounded(.up))) : 0
        case .sinceAnniv:
            num = fullAnniversaries(from: t, to: now)
        case .untilRepeat:
            num = daysToNextRepeat(of: t, now: now)
        case .birthday:
            break // 已在上面提前 return，不会到达；仅满足穷举
        }
        numberLabel.stringValue = "\(num)"
        unitLabel.stringValue = mode.unit
    }

    // 周年计数：已满的完整周年
    func fullAnniversaries(from base: Date, to now: Date) -> Int {
        if base > now { return 0 }
        let cal = Calendar.current
        var y = cal.dateComponents([.year], from: base, to: now).year ?? 0
        let bc = cal.dateComponents([.month, .day], from: base)
        let nc = cal.dateComponents([.month, .day], from: now)
        if nc.month! < bc.month! || (nc.month! == bc.month! && nc.day! < bc.day!) {
            y -= 1
        }
        return max(0, y)
    }

    // 最近重复日：下一个未来最近的同月日，距今整天数（今天恰好则 0）
    func daysToNextRepeat(of base: Date, now: Date) -> Int {
        let cal = Calendar.current
        let bc = cal.dateComponents([.month, .day], from: base)
        let year = cal.component(.year, from: now)
        let today = cal.startOfDay(for: now)
        var target = makeRepeatDate(year: year, month: bc.month!, day: bc.day!, cal: cal)
        if let tg = target, tg < today {
            target = makeRepeatDate(year: year + 1, month: bc.month!, day: bc.day!, cal: cal)
        }
        guard let tg = target else { return 0 }
        return cal.dateComponents([.day], from: today, to: tg).day ?? 0
    }

    // 构造某年某月某日；不存在（如非闰年的 2/29）则回退到该月最后一天
    func makeRepeatDate(year: Int, month: Int, day: Int, cal: Calendar) -> Date? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        if let d = cal.date(from: c) { return d }
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let lastDay = cal.range(of: .day, in: .month, for: first)?.count else { return nil }
        c.day = lastDay
        return cal.date(from: c)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
