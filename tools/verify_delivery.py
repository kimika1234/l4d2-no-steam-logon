# -*- coding: utf-8 -*-
"""
verify_delivery.py — l4d2-no-steam-logon 双平台交付 全量验收
用法: python verify_delivery.py
（默认路径按本机布局，可用环境变量 ROOT 覆盖）
"""
import re, sys, os, pathlib, hashlib

ROOT = pathlib.Path(os.environ.get("ROOT") or pathlib.Path(__file__).resolve().parent.parent)
GD   = ROOT / "gamedata" / "l4d2_block_no_steam_logon_all.txt"
SP   = ROOT / "src" / "l4d2_block_no_steam_logon_all.sp"
SMX  = ROOT / "dist" / "l4d2_block_no_steam_logon_all.smx"
PKGSMX = ROOT / "pkg" / "addons" / "sourcemod" / "plugins" / "l4d2_block_no_steam_logon_all.smx"
PKGGD  = ROOT / "pkg" / "addons" / "sourcemod" / "gamedata" / "l4d2_block_no_steam_logon_all.txt"
DLL  = ROOT / "re" / "engine_srv_win.dll"
BPS  = ROOT / "build.ps1"

fails = []
def check(c, m):
    print(("  [OK]  " if c else "  [FAIL]") + " " + m)
    if not c: fails.append(m)

print("[1] gamedata")
g = GD.read_text(encoding="utf-8", errors="replace")
check('"Offsets"' in g and '"OS"' in g, "含 Offsets/OS")
check('"linux"' in g and '"windows"' in g, "linux + windows 双平台块")
wp = re.findall(r'"(OnValidateAuthTicketResponseHelper::\w+)"', g)
check(len(set(wp)) == 4, f"4 条 patch（3 守卫 + code5）: {sorted(set(n.split('::')[-1] for n in wp))}")

print("[2] .sp 源码")
s = SP.read_text(encoding="utf-8", errors="replace")
check("GameConfGetOffset" in s, "运行时平台检测")
check(not re.search(r"#if\s+defined\s+_linux", s), "无编译期 #if _linux")
check("MemoryPatch g_hPatches" in s, "句柄数组化")
v = re.search(r'#define PLUGIN_VERSION\s+"([^"]+)"', s)
check(bool(v), f"版本号 = {v.group(1) if v else '?'}")

print("[3] smx")
check(SMX.exists() and SMX.stat().st_size > 1000, f"dist smx {SMX.stat().st_size if SMX.exists() else 0} B")

print("[4] engine.dll 静态复算")
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
pe = pefile.PE(str(DLL), fast_load=False); IB = pe.OPTIONAL_HEADER.ImageBase
img = bytearray(pe.OPTIONAL_HEADER.SizeOfImage)
for sec in pe.sections:
    d = sec.get_data(); img[sec.VirtualAddress:sec.VirtualAddress+len(d)] = d
sm = re.search(r'"windows"\s*"((?:\\x[0-9A-Fa-f]{2})+)"', g)
sig = bytes.fromhex(sm.group(1).replace("\\x",""))
hits = [o for o in range(len(img)-len(sig))
        if all(sig[i]==0x2A or img[o+i]==sig[i] for i in range(len(sig)))]
check(len(hits)==1, f"signature 唯一匹配 ({len(hits)})")
ENTRY = hits[0] if len(hits)==1 else -1

# 收集所有 windows patch
patches = {}
for m in re.finditer(r'"(OnValidateAuthTicketResponseHelper::\w+)"\s*\{.*?"windows"\s*\{(.*?)\}', g, re.S):
    o = re.search(r'"offset"\s*"([0-9A-Fa-f]+)h?"', m.group(2))
    v_ = re.search(r'"verify"\s*"((?:\\x[0-9A-Fa-f]{2})+)"', m.group(2))
    p_ = re.search(r'"patch"\s*"((?:\\x[0-9A-Fa-f]{2})+)"', m.group(2))
    if o and v_ and p_:
        patches[m.group(1)] = (int(o.group(1),16),
                               bytes.fromhex(v_.group(1).replace("\\x","")),
                               bytes.fromhex(p_.group(1).replace("\\x","")))
check(len(patches)==4, f"windows patch 数 = {len(patches)}")

# 重定位表检查：verify 目标不能在重定位表
reloc = set()
if hasattr(pe, "DIRECTORY_ENTRY_BASERELOC"):
    for r in pe.DIRECTORY_ENTRY_BASERELOC:
        for e in r.entries: reloc.add(e.rva)

if ENTRY >= 0:
    for n,(o,v_,p_) in sorted(patches.items()):
        tgt = ENTRY + o
        ok_hit = bytes(img[tgt:tgt+len(v_)]) == v_
        check(ok_hit, f"{n.split('::')[-1]} verify 命中 @RVA {hex(tgt)}")
        check(len(v_)==len(p_), f"{n.split('::')[-1]} verify/patch 等长")
        check(tgt not in reloc, f"{n.split('::')[-1]} 目标不在重定位表（ASLR 安全）")
    # 应用并反汇编
    pt = bytearray(img)
    for n,(o,v_,p_) in patches.items(): pt[ENTRY+o:ENTRY+o+len(p_)] = p_
    md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
    tg = set()
    for n,(o,v_,p_) in sorted(patches.items()):
        ins = list(md.disasm(bytes(pt[ENTRY+o:ENTRY+o+len(p_)+8]), IB+ENTRY+o))[0]
        check(ins.mnemonic=="jmp", f"{n.split('::')[-1]} -> jmp {ins.op_str}")
        tg.add(ins.operands[0].imm)
    check(len(tg)==1 and (next(iter(tg))-IB)==0x12d891,
          f"全部 jmp 指向不踢路径 0x12d891 ({[hex(t) for t in tg]})")

print("[5] build.ps1")
b = BPS.read_bytes()
check(b[:3]==b"\xEF\xBB\xBF", "UTF-8 BOM")
bt = b.decode("utf-8-sig")
check("<server>" not in bt, "无 '<' 误重定向")
check("Compress-Archive" in bt, "含 zip 打包步骤")

print("[6] pkg/dist 一致")
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
check(h(SMX)==h(PKGSMX), "pkg smx == dist smx")
check(h(GD)==h(PKGGD), "pkg gamedata == 源 gamedata")

print("\n" + "="*60)
print("验收通过 ✓" if not fails else f"失败 {len(fails)} 项：{fails}")
print("="*60)
sys.exit(1 if fails else 0)
