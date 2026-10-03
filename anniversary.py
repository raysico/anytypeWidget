#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""
anniversary — 纪念日倒数命令行

数据模型：把「纪念日清单」存成一个 Anytype 对象（type=note），
对象内容是一列形如 "- 名称|YYYY-MM-DD" 的列表项。
读写全部走官方 Anytype 桌面端的本地 REST API（127.0.0.1:31009）。
同步那整块脏活由官方客户端通过 any-sync 网络完成 —— 因此：
  这台 Mac / 安卓端 Anytype / 任意设备改同一个空间里的对象，都会互相同步。

配置：~/.whynownote/wnn.json（含 api_key，权限 600）

命令：
  anniversary init [--api-key KEY] [--space-id ID]   初始化配置并确保对象存在
  anniversary add 名称 日期                           新增一条（日期 YYYY-MM-DD）
  anniversary set 名称 日期                           修改一条的日期
  anniversary rm 名称                                删除一条
  anniversary list                                   人类可读列表（含倒数天数）
  anniversary read                                   输出 JSON（供小组件）
"""
import sys
import os
import json
import datetime
import urllib.request
import urllib.error

CONFIG_PATH = os.path.expanduser("~/.whynownote/wnn.json")
OBJECT_NAME = "🎂 纪念日"
BASE_URL_DEFAULT = "http://127.0.0.1:31009"


def log_err(msg):
    sys.stderr.write(msg + "\n")


def load_config():
    if not os.path.exists(CONFIG_PATH):
        log_err("尚未初始化。请先运行：anniversary init --api-key <你的API Key>")
        sys.exit(1)
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg):
    d = os.path.dirname(CONFIG_PATH)
    os.makedirs(d, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.chmod(CONFIG_PATH, 0o600)


def api(cfg, method, path, body=None):
    url = cfg["base_url"] + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + cfg["api_key"])
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        msg = e.read().decode("utf-8", "replace")
        log_err(f"API {method} {path} 失败：{e.code} {msg}")
        sys.exit(1)


def ensure_object(cfg):
    """若配置里没有对象 id，就创建「纪念日」对象；有则返回。幂等。"""
    if cfg.get("object_id"):
        return cfg["object_id"]
    obj = api(cfg, "POST", f"/v2/spaces/{cfg['space_id']}/objects", {
        "type": "note", "name": OBJECT_NAME, "markdown": "",
    })
    cfg["object_id"] = obj["id"]
    save_config(cfg)
    return obj["id"]


def read_entries(cfg):
    """读回对象，返回 [{"name","date","block_id","text"}]（按文档顺序）。"""
    obj_id = ensure_object(cfg)
    obj = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/objects/{obj_id}")
    entries = []
    for b in obj.get("blocks", []):
        t = (b.get("text") or "").strip()
        if b.get("type") != "bulleted_list_item" or not t:
            continue
        if "|" in t:
            name, date = t.rsplit("|", 1)
            name, date = name.strip(), date.strip()
        else:
            name, date = t, ""
        entries.append({"name": name, "date": date, "block_id": b.get("id"), "text": t})
    return entries


def rewrite(cfg, entries):
    """删掉所有旧列表项，再以 markdown 重插。返回成功与否。"""
    obj_id = ensure_object(cfg)
    ops = []
    for e in entries:
        if e.get("block_id"):
            ops.append({"op": "delete_block", "id": e["block_id"]})
    if entries:
        md = "\n".join(f"- {e['name']}|{e['date']}" for e in entries)
        ops.append({"op": "insert_blocks", "markdown": md})
    if not ops:
        return
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{obj_id}", {"ops": ops})


def parse_date(s):
    try:
        return datetime.date.fromisoformat(s.strip())
    except ValueError:
        return None


def next_occurrence(date, today):
    """计算某个日期下一次（含本年/次年）的周年纪念日。date 是首次发生的日期。"""
    cand = date.replace(year=today.year)
    if cand < today:
        cand = date.replace(year=today.year + 1)
    return cand


def build_view(cfg, today=None):
    today = today or datetime.date.today()
    entries = read_entries(cfg)
    items = []
    for e in entries:
        d = parse_date(e["date"])
        if not d:
            items.append({"name": e["name"], "date": e["date"], "days_until": None,
                          "next": None, "label": "日期无效"})
            continue
        nxt = next_occurrence(d, today)
        days = (nxt - today).days
        if days == 0:
            label = "就是今天 🎉"
        else:
            label = f"还有 {days} 天"
        items.append({"name": e["name"], "date": d.strftime("%Y-%m-%d"),
                      "next": nxt.strftime("%Y-%m-%d"), "days_until": days, "label": label})
    # 升序按最近发生排
    items.sort(key=lambda x: x["days_until"] if x["days_until"] is not None else 10 ** 9)
    return items


# ---------- 命令 ----------

def cmd_init(args):
    api_key = args.get("api_key")
    space_id = args.get("space_id")
    if not api_key:
        log_err("缺少 --api-key。请提供在 Anytype 桌面端授权得到的 API Key。")
        sys.exit(1)
    cfg = {"base_url": BASE_URL_DEFAULT, "api_key": api_key}
    if not space_id:
        spaces = api(cfg, "GET", "/v2/spaces").get("data", [])
        if not spaces:
            log_err("账号下没有可用的空间。")
            sys.exit(1)
        space_id = spaces[0]["id"]
    cfg["space_id"] = space_id
    cfg["object_name"] = OBJECT_NAME
    save_config(cfg)
    ensure_object(cfg)
    print(f"✅ 已初始化：space={space_id}，对象=「{OBJECT_NAME}」（id={cfg['object_id']}）")
    print(f"   配置：{CONFIG_PATH}")
    print(f"   试试：anniversary add 恋爱纪念日 2020-05-20")


def cmd_add(args):
    cfg = load_config()
    name, date = args["name"], args["date"]
    if not parse_date(date):
        log_err(f"日期格式应为 YYYY-MM-DD，收到：{date}")
        sys.exit(1)
    entries = read_entries(cfg)
    if any(e["name"] == name for e in entries):
        log_err(f"已存在同名纪念日「{name}」，如需改日期用：anniversary set {name} <日期>")
        sys.exit(1)
    entries.append({"name": name, "date": date})
    rewrite(cfg, entries)
    print(f"✅ 已添加：{name}（{date}）→ 已同步到 any-sync 空间")


def cmd_set(args):
    cfg = load_config()
    name, date = args["name"], args["date"]
    if not parse_date(date):
        log_err(f"日期格式应为 YYYY-MM-DD，收到：{date}")
        sys.exit(1)
    entries = read_entries(cfg)
    hit = False
    for e in entries:
        if e["name"] == name:
            e["date"] = date
            hit = True
    if not hit:
        log_err(f"没有叫「{name}」的纪念日。先 add 或用 anniversary list 查看。")
        sys.exit(1)
    rewrite(cfg, entries)
    print(f"✅ 已更新：{name} → {date}（已同步到 any-sync 空间）")


def cmd_rm(args):
    cfg = load_config()
    name = args["name"]
    entries = read_entries(cfg)
    kept = [e for e in entries if e["name"] != name]
    if len(kept) == len(entries):
        log_err(f"没有叫「{name}」的纪念日。")
        sys.exit(1)
    rewrite(cfg, kept)
    print(f"✅ 已删除：{name}")


def cmd_list(args):
    cfg = load_config()
    today = datetime.date.today()
    print(f"今天：{today.isoformat()}")
    for it in build_view(cfg, today):
        if it["days_until"] is None:
            print(f"  {it['name']}  （日期无效：{it['date']}）")
        else:
            print(f"  {it['name']}  下一次 {it['next']}  {it['label']}")


def cmd_read(args):
    cfg = load_config()
    today = datetime.date.today()
    data = {"today": today.isoformat(), "anniversaries": build_view(cfg, today)}
    print(json.dumps(data, ensure_ascii=False))


# ---------- 类型化命令（小组件数据入口）----------

ANNIVERSARY_TYPE_KEY = "ji_nian_ri"


def list_objects(cfg, type_key=None):
    """列出指定类型对象，返回 [{id,name}]。type_key 缺省为「纪念日」。"""
    body = {"filters": [{"property": "type", "condition": "equal", "value": type_key or ANNIVERSARY_TYPE_KEY}]}
    r = api(cfg, "POST", f"/v2/spaces/{cfg['space_id']}/search?limit=100", body)
    return r.get("data", [])


def cmd_objects(args):
    cfg = load_config()
    type_key = args[0] if args else None
    objs = [{"id": o.get("id"), "name": o.get("name")} for o in list_objects(cfg, type_key)]
    print(json.dumps(objs, ensure_ascii=False))


def api_raw(cfg, method, path, body=None):
    """返回原始字节（用于下载文件内容等非 JSON 响应）。"""
    url = cfg["base_url"] + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + cfg["api_key"])
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read()


def _first_select(v):
    """select/multi_select 在属性里可能是数组或单值，取第一个文本值。"""
    if isinstance(v, list):
        return v[0] if v else None
    return v


def cmd_read_object(args):
    cfg = load_config()
    oid = args["id"]
    obj = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/objects/{oid}")
    props = obj.get("properties", {})
    out = {
        "id": oid,
        "name": props.get("name"),
        "date_iso": props.get("ji_nian_ri_ri_qi"),
        "color": props.get("yan_se"),
        "type": obj.get("type"),
        "icon": obj.get("icon"),
        "mo_shi": props.get("mo_shi"),
        "mi_ni_mo_shi": props.get("mi_ni_mo_shi"),
        "dang_qian_kuan_du": props.get("dang_qian_kuan_du"),
        "dang_qian_gao_du": props.get("dang_qian_gao_du"),
    }
    # 资产（zi_chan）扩展字段；非资产对象这些键为 None，组件按 type 分流
    if obj.get("type") == ASSET_TYPE_KEY:
        out.update({
            "gou_mai_iso": props.get(A_GOU_MAI),
            "bao_xiu_iso": props.get(A_BAO_XIU),
            "price": props.get(A_PRICE),
            "uses": props.get(A_USES),
            "period": _first_select(props.get(A_PERIOD)),
            "asset_mode": _first_select(props.get(A_ASSET_MODE)),
        })
    print(json.dumps(out, ensure_ascii=False))


def cmd_set_mini(args):
    """把「迷你模式」写回对象（select 字段 mi_ni_mo_shi）：set-mini <对象id> <是|否>。"""
    cfg = load_config()
    oid = args["id"]
    val = args["value"]
    if val not in ("是", "否"):
        log_err("迷你模式取值只能是「是」或「否」"); sys.exit(1)
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": {"mi_ni_mo_shi": [val]}}]})
    print(json.dumps({"ok": True, "mi_ni_mo_shi": val}))


def cmd_set_size(args):
    """把当前宽度/当前高度写回对象（number 字段）。"""
    cfg = load_config()
    oid = args["id"]
    try:
        w = int(args["w"]); h = int(args["h"])
    except ValueError:
        log_err("宽度/高度应为整数"); sys.exit(1)
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": {"dang_qian_kuan_du": w, "dang_qian_gao_du": h}}]})
    print(json.dumps({"ok": True, "w": w, "h": h}))


def cmd_inc_uses(args):
    """资产「使用次数」增减：inc-uses <对象id> [增量，默认1，减一传-1]；结果不低于 0。"""
    cfg = load_config()
    oid = args["id"]
    try:
        delta = int(args.get("delta") or "1")
    except ValueError:
        log_err("增量应为整数（如 1 或 -1）"); sys.exit(1)
    obj = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/objects/{oid}")
    cur = (obj.get("properties") or {}).get(A_USES)
    try:
        n0 = int(float(cur)) if cur is not None else 0
    except (TypeError, ValueError):
        n0 = 0
    n = max(0, n0 + delta)
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": {A_USES: n}}]})
    print(json.dumps({"ok": True, "uses": n}, ensure_ascii=False))


def cmd_types(args):
    """列空间内所有对象类型 [{key, name}]。"""
    cfg = load_config()
    r = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/types")
    ts = [{"key": t.get("key"), "name": t.get("name")} for t in r.get("data", [])]
    print(json.dumps(ts, ensure_ascii=False))


def cmd_icon_image(args):
    """取对象图标。file→下载图片到 out_path；emoji→返回 emoji；icon→返回名字+颜色。"""
    cfg = load_config()
    oid = args["id"]
    out = args.get("out")
    obj = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/objects/{oid}")
    icon = obj.get("icon") or {}
    fmt = icon.get("format")
    result = {"format": fmt}
    if fmt == "file" and icon.get("file"):
        data = api_raw(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/files/{icon['file']}/content")
        if out:
            with open(out, "wb") as f:
                f.write(data)
            result["path"] = out
        else:
            result["bytes"] = len(data)
    elif fmt == "emoji":
        result["emoji"] = icon.get("emoji")
    elif fmt == "icon":
        result["name"] = icon.get("name")
        result["color"] = icon.get("color")
    print(json.dumps(result, ensure_ascii=False))


def cmd_set_date(args):
    cfg = load_config()
    oid = args["id"]
    raw = args["datetime"]
    # 把本地 "YYYY-MM-DD HH:MM"（或 YYYY-MM-DD）转成 UTC ISO
    s = raw.strip()
    fmt = "%Y-%m-%d %H:%M" if " " in s else "%Y-%m-%d"
    try:
        dt = datetime.datetime.strptime(s, fmt)
    except ValueError:
        log_err(f"时间格式应为 YYYY-MM-DD HH:MM 或 YYYY-MM-DD，收到：{raw}")
        sys.exit(1)
    # 解释为本地时区，转 UTC
    local = dt.astimezone()  # naive → 当前本地时区
    utc_iso = local.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    obj_id = ensure_object(cfg)  # noop，仅为占位（config 里是旧对象，不影响）
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": {"ji_nian_ri_ri_qi": utc_iso}}]})
    print(f"✅ 已把「纪念日日期」设为 {utc_iso}（UTC），即本地 {s}")


def cmd_widget(args):
    cfg = load_config()
    name = args.get("name")
    mode = args.get("mode")
    import subprocess, time as _t
    objs = list_objects(cfg)
    match = None
    if name:
        match = next((o for o in objs if o.get("name") == name), None)
        if not match:
            log_err(f"没找到叫「{name}」的纪念日对象。可用 anniversary objects 查看。")
            sys.exit(1)
    else:
        match = objs[0] if objs else None
        if not match:
            log_err("还没有任何「纪念日」对象。")
            sys.exit(1)
    iid = f"w{int(_t.time())}"
    app = os.path.join(os.path.dirname(os.path.realpath(__file__)), "CountdownWidget.app")
    # 预写实例配置（含模式），app 启动即加载
    inst_dir = os.path.expanduser("~/.whynownote/widgets")
    os.makedirs(inst_dir, exist_ok=True)
    inst = {"object_id": match["id"], "mode": mode or "since_day", "x": 0, "y": 0}
    with open(os.path.join(inst_dir, iid + ".json"), "w", encoding="utf-8") as f:
        json.dump(inst, f, ensure_ascii=False)
    subprocess.Popen(["/usr/bin/open", "-n", app, "--args", "--instance", iid, "--object", match["id"]])
    print(f"✅ 已开启新小组件窗口，绑定「{match['name']}」，模式={mode or '正计日'}")


MODE_MAP = {
    "正计日": "since_day",
    "倒计日": "until_day",
    "正计时": "since_hour",
    "倒计时": "until_hour",
    "周年计数": "since_anniv",
    "最近重复日": "until_repeat",
    "生日": "birthday",
}


# ---------- 聚合面板（类型化对象：ju_he_mian_ban）----------

PANEL_TYPE_KEY = "ju_he_mian_ban"
ASSET_TYPE_KEY = "zi_chan"

# 资产（zi_chan）字段 key（以类型定义实际 key 为准）
A_GOU_MAI = "gou_mai_ri_qi"              # 购买日期（date）
A_BAO_XIU = "bao_xiu_dao_qi_ri"          # 保修到期日（date）
A_PRICE = "gou_mai_jie_ge_yuan"          # 购买价格（元，number）
A_USES = "shi_yong_ci_shu"               # 使用次数（number）
A_PERIOD = "ji_shu_zhou_qi"              # 计数周期（select：日/月/年…）
A_ASSET_MODE = "mo_ren_mo_shi"           # 资产默认模式（select：使用次数计费/使用时长计费）

# 面板字段 key（以类型定义实际 key 为准；此处仅默认值/回写用）
P_MO_SHI = "mo_shi"                                  # 日期计数默认模式（仅作筛选值）
P_SHAI_XUAN = "shai_xuan_mo_shi"                     # 筛选意愿维度
P_LEI_XING_IDS = "dui_xiang_lei_xing"                # 类型筛选值（类型对象 id）
P_LEI_XING_NAMES = "dui_xiang_lei_xing_shai_xuan_xiang"  # 类型筛选值（中文名镜像）
P_FEN_LEI = "fen_lei"                                # 分类筛选值
P_BIAO_QIAN = "biao_qian"                            # 标签筛选值
P_XUAN_ZHONG = "xian_shi_de_dui_xiang"               # 手动勾选的成员（最高优先）
P_PAI_XU = "pai_xu_mo_shi"                           # 排序模式
P_XIAN_ZHI = "xian_zhi_xian_shi_shu_liang"           # 限制显示数量

# 筛选意愿维度的中文取值
DIM_TYPE = "对象类型"
DIM_MODE = "日期计数默认模式"
DIM_FEN_LEI = "分类"
DIM_BIAO_QIAN = "标签"

# 与 Swift Mode 等价的模式归一（标题/别名/模糊包含）
_MODE_TITLES = {
    "正计日": "since_day", "倒计日": "until_day",
    "正计时": "since_hour", "倒计时": "until_hour",
    "周年计数": "since_anniv", "最近重复日": "until_repeat",
    "生日": "birthday",
}
_MODE_ALIASES = {"距离最近的重复日": "until_repeat"}


def normalize_mode(s):
    """中文模式文本 -> raw mode（与 Swift Mode.fromText 同口径）。无法识别返回 None。"""
    if not s:
        return None
    if s in _MODE_TITLES:
        return _MODE_TITLES[s]
    if s in _MODE_ALIASES:
        return _MODE_ALIASES[s]
    for t, v in _MODE_TITLES.items():
        if t in s:
            return v
    return None


def list_space_types(cfg):
    """空间内全部类型 [{key,name}]。"""
    r = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/types")
    return [{"key": t.get("key"), "name": t.get("name")} for t in r.get("data", [])]


def resolve_type_keys(cfg, props, types_list):
    """面板类型筛选值 -> 成员类型 key 列表（id 字段与中文名镜像取并集）。"""
    keys = []
    name_to_key = {t.get("name"): t.get("key") for t in types_list}
    for nm in props.get(P_LEI_XING_NAMES) or []:
        k = name_to_key.get(nm)
        if k and k not in keys:
            keys.append(k)
    ids = props.get(P_LEI_XING_IDS) or []
    if ids:
        want = set(ids)
        for t in types_list:  # 命中即停，避免全量遍历
            k = t.get("key")
            if not k or k in keys:
                continue
            try:
                d = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/types/{k}")
            except SystemExit:
                continue
            if d.get("id") in want:
                keys.append(k)
                want.discard(d.get("id"))
                if not want:
                    break
    return keys


def member_brief(obj_json, type_key, type_name):
    """从成员对象完整 JSON 抽取面板行所需字段（纪念日/资产各自字段；其余仅通用项）。"""
    p = obj_json.get("properties", {}) or {}
    mo = p.get("mo_shi") or []
    m = {
        "id": obj_json.get("id"),
        "name": p.get("name"),
        "type": type_key,
        "type_name": type_name,
        "date_iso": p.get("ji_nian_ri_ri_qi"),
        "color": p.get("yan_se"),
        "mo_shi": mo[0] if isinstance(mo, list) and mo else (mo or None),
        "fen_lei": p.get("fen_lei") or [],
        "biao_qian": p.get("biao_qian") or [],
    }
    if type_key == ASSET_TYPE_KEY:
        m.update({
            "icon": obj_json.get("icon"),
            "gou_mai_iso": p.get(A_GOU_MAI),
            "bao_xiu_iso": p.get(A_BAO_XIU),
            "price": p.get(A_PRICE),
            "uses": p.get(A_USES),
            "period": _first_select(p.get(A_PERIOD)),
            "asset_mode": _first_select(p.get(A_ASSET_MODE)),
        })
    return m


def passes_panel_filters(member, dims, props):
    """全部 AND：维度之间 AND，同维度多值也 AND。"""
    def vals(v):
        return v if isinstance(v, list) else [v]

    if DIM_MODE in dims:
        want = props.get(P_MO_SHI) or []
        want_norm = normalize_mode(want[0]) if want else None
        # 面板配了维度但没配值：该维度放行（无法判断）
        if want_norm is not None and normalize_mode(member.get("mo_shi")) != want_norm:
            return False
    if DIM_FEN_LEI in dims:
        need = vals(props.get(P_FEN_LEI) or [])
        have = set(member.get("fen_lei") or [])
        if need and not all(v in have for v in need):
            return False
    if DIM_BIAO_QIAN in dims:
        need = vals(props.get(P_BIAO_QIAN) or [])
        have = set(member.get("biao_qian") or [])
        if need and not all(v in have for v in need):
            return False
    return True


def cmd_panel_data(args):
    """输出面板配置 + 筛选后候选 + 手选成员（一次调用完成解析与筛选）。"""
    cfg = load_config()
    oid = args["id"]
    sid = cfg["space_id"]
    panel = api(cfg, "GET", f"/v2/spaces/{sid}/objects/{oid}")
    props = panel.get("properties", {}) or {}
    dims = props.get(P_SHAI_XUAN) or []

    types_list = list_space_types(cfg)
    type_name = {t.get("key"): t.get("name") for t in types_list}

    # 候选类型：直接读两个类型值字段（历史数据无意愿维度也兼容）；都没有则默认纪念日
    type_keys = resolve_type_keys(cfg, props, types_list)
    if not type_keys:
        type_keys = [ANNIVERSARY_TYPE_KEY]

    # 拉取候选类型下全部对象（未筛选全集，供手选成员复用）
    gathered = {}   # id -> member
    for tk in type_keys:
        for o in list_objects(cfg, tk):
            mid = o.get("id")
            if not mid or mid in gathered:
                continue
            try:
                full = api(cfg, "GET", f"/v2/spaces/{sid}/objects/{mid}")
            except SystemExit:
                continue
            gathered[mid] = member_brief(full, tk, type_name.get(tk, tk))

    panel_modes = props.get(P_MO_SHI) or []
    candidates = [m for m in gathered.values()
                  if passes_panel_filters(m, dims, props)]

    # 手选优先：即使不满足筛选也取数回传
    selected_ids = props.get(P_XUAN_ZHONG) or []
    selected_rows = []
    for mid in selected_ids:
        if mid in gathered:
            selected_rows.append(gathered[mid])
        else:
            try:
                full = api(cfg, "GET", f"/v2/spaces/{sid}/objects/{mid}")
                tk = full.get("type")
                selected_rows.append(member_brief(full, tk, type_name.get(tk, tk)))
            except SystemExit:
                continue

    pai = props.get(P_PAI_XU) or []
    # 面板类型字段定义（供组件解析 {中文字段名} 模板变量）
    try:
        td = api(cfg, "GET", f"/v2/spaces/{sid}/types/{PANEL_TYPE_KEY}")
        fields = [{"key": pd.get("property"), "name": pd.get("name"),
                   "format": pd.get("format")}
                  for pd in td.get("type_settings", {}).get("property_definitions", [])
                  if pd.get("section") != "hidden"]
    except SystemExit:
        fields = []

    out = {
        "id": oid,
        "name": props.get("name"),
        "mode_filter_text": panel_modes[0] if panel_modes else None,
        "sort_text": pai[0] if pai else None,
        "limit": props.get(P_XIAN_ZHI) or 0,
        "filter": {
            "type": DIM_TYPE in dims or bool(props.get(P_LEI_XING_IDS) or props.get(P_LEI_XING_NAMES)),
            "mode": DIM_MODE in dims,
            "fen_lei": DIM_FEN_LEI in dims,
            "biao_qian": DIM_BIAO_QIAN in dims,
        },
        "dims": dims,
        "type_keys": type_keys,
        "fen_lei": props.get(P_FEN_LEI) or [],
        "biao_qian": props.get(P_BIAO_QIAN) or [],
        "selected": selected_ids,
        "candidates": candidates,
        "selected_rows": selected_rows,
        "fields": fields,
        "props": props,
        "all_types": types_list,
    }
    print(json.dumps(out, ensure_ascii=False))


def cmd_panel_set(args):
    """对面板对象做一次 set_properties 回写：panel-set <id> '<属性json>'。"""
    cfg = load_config()
    oid = args["id"]
    try:
        updates = json.loads(args["json"])
    except (ValueError, TypeError):
        log_err("属性必须是合法 JSON，例如：'{\"pai_xu_mo_shi\": [\"名称升序\"]}'")
        sys.exit(1)
    if not isinstance(updates, dict) or not updates:
        log_err("属性 JSON 必须是非空对象")
        sys.exit(1)
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": updates}]})
    print(json.dumps({"ok": True}, ensure_ascii=False))


def cmd_panel_set_types(args):
    """成员类型筛选回写：panel-set-types <面板id> <类型key逗号列表（空=清除）>。
    同时写 id 字段、中文名镜像，并维护 shai_xuan_mo_shi 的「对象类型」意愿。"""
    cfg = load_config()
    oid = args["id"]
    raw = (args.get("keys") or "").strip()
    keys = [k for k in raw.split(",") if k] if raw else []
    types_list = list_space_types(cfg)
    name_by_key = {t.get("key"): t.get("name") for t in types_list}
    names = [name_by_key[k] for k in keys if k in name_by_key]
    ids = []
    if keys:
        want = set(keys)
        for t in types_list:
            k = t.get("key")
            if k not in want:
                continue
            try:
                d = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/types/{k}")
                ids.append(d.get("id"))
            except SystemExit:
                continue
    # 维护筛选意愿
    panel = api(cfg, "GET", f"/v2/spaces/{cfg['space_id']}/objects/{oid}")
    dims = [d for d in (panel.get("properties", {}) or {}).get(P_SHAI_XUAN, []) if d != DIM_TYPE]
    if keys:
        dims.append(DIM_TYPE)
    updates = {P_LEI_XING_IDS: ids, P_LEI_XING_NAMES: names, P_SHAI_XUAN: dims}
    api(cfg, "PATCH", f"/v2/spaces/{cfg['space_id']}/objects/{oid}",
        {"ops": [{"op": "set_properties", "set": updates}]})
    print(json.dumps({"ok": True, "keys": keys, "names": names}, ensure_ascii=False))


def cmd_new_panel(args):
    """新建一个聚合面板对象（仅此类型支持由组件创建）。new-panel [名称]"""
    cfg = load_config()
    name = (args.get("name") or "新建看板").strip() or "新建看板"
    body = {
        "type": PANEL_TYPE_KEY,
        "name": name,
        "properties": {
            P_PAI_XU: ["名称升序"],
            P_XIAN_ZHI: 0,
            P_XUAN_ZHONG: [],
        },
    }
    obj = api(cfg, "POST", f"/v2/spaces/{cfg['space_id']}/objects", body)
    print(json.dumps({"id": obj["id"], "name": name}, ensure_ascii=False))


def cmd_panel_launch(args):
    """anniversary panel [名称]：绑定聚合面板对象开一个面板窗口。"""
    cfg = load_config()
    name = args.get("name")
    import subprocess, time as _t
    objs = list_objects(cfg, PANEL_TYPE_KEY)
    match = next((o for o in objs if o.get("name") == name), None) if name else (objs[0] if objs else None)
    if not match:
        log_err("没找到匹配的聚合面板对象。可用 anniversary objects ju_he_mian_ban 查看。")
        sys.exit(1)
    iid = f"w{int(_t.time())}"
    app = os.path.join(os.path.dirname(os.path.realpath(__file__)), "CountdownWidget.app")
    inst_dir = os.path.expanduser("~/.whynownote/widgets")
    os.makedirs(inst_dir, exist_ok=True)
    inst = {"object_id": match["id"], "mode": "since_day", "agg": True, "x": 0, "y": 0}
    with open(os.path.join(inst_dir, iid + ".json"), "w", encoding="utf-8") as f:
        json.dump(inst, f, ensure_ascii=False)
    subprocess.Popen(["/usr/bin/open", "-n", app, "--args", "--instance", iid, "--object", match["id"]])
    print(f"✅ 已开启聚合面板窗口，绑定「{match['name']}」")





def main(argv):
    if len(argv) < 1:
        log_err(__doc__)
        sys.exit(1)
    cmd = argv[0]
    args = argv[1:]
    if cmd == "init":
        kw = {}
        i = 0
        while i < len(args):
            a = args[i]
            if a == "--api-key" and i + 1 < len(args):
                kw["api_key"] = args[i + 1]; i += 2
            elif a == "--space-id" and i + 1 < len(args):
                kw["space_id"] = args[i + 1]; i += 2
            else:
                log_err(f"未知参数：{a}"); sys.exit(1)
        cmd_init(kw)
    elif cmd == "add":
        if len(args) != 2:
            log_err("用法：anniversary add 名称 日期"); sys.exit(1)
        cmd_add({"name": args[0], "date": args[1]})
    elif cmd == "set":
        if len(args) != 2:
            log_err("用法：anniversary set 名称 日期"); sys.exit(1)
        cmd_set({"name": args[0], "date": args[1]})
    elif cmd == "rm":
        if len(args) != 1:
            log_err("用法：anniversary rm 名称"); sys.exit(1)
        cmd_rm({"name": args[0]})
    elif cmd == "list":
        cmd_list(args)
    elif cmd == "read":
        cmd_read(args)
    elif cmd == "objects":
        cmd_objects(args)
    elif cmd == "read-object":
        if len(args) != 1:
            log_err("用法：anniversary read-object <对象id>"); sys.exit(1)
        cmd_read_object({"id": args[0]})
    elif cmd == "icon-image":
        if len(args) not in (1, 2):
            log_err("用法：anniversary icon-image <对象id> [输出路径]"); sys.exit(1)
        cmd_icon_image({"id": args[0], "out": args[1] if len(args) == 2 else None})
    elif cmd == "set-size":
        if len(args) != 3:
            log_err("用法：anniversary set-size <对象id> <宽> <高>"); sys.exit(1)
        cmd_set_size({"id": args[0], "w": args[1], "h": args[2]})
    elif cmd == "set-mini":
        if len(args) != 2:
            log_err("用法：anniversary set-mini <对象id> <是|否>"); sys.exit(1)
        cmd_set_mini({"id": args[0], "value": args[1]})
    elif cmd == "inc-uses":
        if len(args) not in (1, 2):
            log_err("用法：anniversary inc-uses <对象id> [增量，默认1，减一-1]"); sys.exit(1)
        cmd_inc_uses({"id": args[0], "delta": args[1] if len(args) == 2 else None})
    elif cmd == "types":
        cmd_types(args)
    elif cmd == "set-date":
        if len(args) != 2:
            log_err("用法：anniversary set-date <对象id> \"YYYY-MM-DD HH:MM\""); sys.exit(1)
        cmd_set_date({"id": args[0], "datetime": args[1]})
    elif cmd == "widget":
        name = args[0] if len(args) >= 1 else None
        mode = MODE_MAP.get(args[1]) if len(args) >= 2 and args[1] in MODE_MAP else None
        cmd_widget({"name": name, "mode": mode})
    elif cmd == "panel":
        name = args[0] if len(args) >= 1 else None
        cmd_panel_launch({"name": name})
    elif cmd == "panel-data":
        if len(args) != 1:
            log_err("用法：anniversary panel-data <聚合面板id>"); sys.exit(1)
        cmd_panel_data({"id": args[0]})
    elif cmd == "panel-set":
        if len(args) != 2:
            log_err("用法：anniversary panel-set <聚合面板id> '<属性json>'"); sys.exit(1)
        cmd_panel_set({"id": args[0], "json": args[1]})
    elif cmd == "panel-set-types":
        if len(args) != 2:
            log_err("用法：anniversary panel-set-types <面板id> <类型key逗号列表>"); sys.exit(1)
        cmd_panel_set_types({"id": args[0], "keys": args[1]})
    elif cmd == "new-panel":
        cmd_new_panel({"name": args[0] if len(args) >= 1 else None})
    else:
        log_err(f"未知命令：{cmd}")
        log_err(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
