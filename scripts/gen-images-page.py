#!/usr/bin/env python3
"""Generate the images download page (static HTML) from release assets.

Input:
  assets.tsv   — "name<TAB>size<TAB>url" per line (gh release view --json assets)
  meta.json    — {"tag": ..., "generated_at": ..., "onedrive_url": ...}
Output: standalone HTML on stdout (no external deps).

Filename grammar (armbian image names self-describe everything):
  Armbian-unofficial_26.11.0-trunk_Recomputer-<board>_<release>_vendor_<kernel>_<variant>[_<ota>|_AB_PART|-crypt].img[.xz][.sha256|.txt|…]
    board   — captured verbatim as the section id/dir (rk3576-devkit, rk3576-industrial, …)
    variant — trailing "_minimal" → cli, "_gnome_desktop" → desktop
                (NOT the release token: noble/trixie/resolute only say the distro)
    mode    — "_AB_PART" → A/B, otherwise recovery
    crypt   — "-crypt" → encrypted image
    OTA     — "<base>_OTA.tar.gz" / "<base>_OTA.checksums"
"""

import html
import json
import re
import sys
from collections import defaultdict

BOARD_PAT = re.compile(r"Recomputer-([A-Za-z0-9][A-Za-z0-9-]*?)_")


def parse(name, size, url):
    m = BOARD_PAT.search(name)
    if not m:
        return None
    board = m.group(1)
    variant = "desktop" if "_gnome_desktop" in name else ("cli" if "_minimal" in name else None)
    if variant is None:
        return None
    mode = "ab" if "_AB_PART" in name else "recovery"
    crypt = "-crypt" in name
    kind = None
    if re.search(r"\.\d+\.part$", name):
        kind = "part"
    elif name.endswith(".img.xz.sha256"):
        kind = "sha256"
    elif name.endswith(".img.xz"):
        kind = "img"
    elif name.endswith(".img.sha"):
        kind = "sha"
    elif name.endswith(".img.txt"):
        kind = "txt"
    elif name.endswith("_OTA.tar.gz"):
        kind = "ota"
    elif name.endswith("_OTA.checksums"):
        kind = "chk"
    elif name.endswith(".sha256"):
        kind = "sha256"          # sidecar of a split file
    if kind is None:
        return None
    return board, variant, mode, crypt, kind, name, size, url


def human(n):
    n = float(n)
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return f"{int(n)}{unit}" if unit in ("B", "K") else f"{n:.1f}{unit}"
        n /= 1024


CHIP = {"img": "镜像", "sha256": "sha256", "sha": "sha", "txt": "构建信息",
        "ota": "OTA 包", "chk": "校验", "part": None}
VARIANT_LABEL = {"cli": "CLI", "desktop": "桌面"}


def render(rows, meta):
    # rows: {(board, variant, mode, crypt)} -> {kind: (name,size,url)|list-of-parts}
    boards = sorted({k[0] for k in rows})
    sec_html = []
    for b in boards:
        cards = []
        for variant in ("cli", "desktop"):
            for mode in ("recovery", "ab"):
                for crypt in (False, True):
                    d = rows.get((b, variant, mode, crypt))
                    if not d:
                        continue
                    title = VARIANT_LABEL[variant]
                    if mode == "ab":
                        title += " · A/B"
                    if crypt:
                        title += " · 加密"
                    chips = []
                    for kind in ("img", "part", "sha256", "sha", "txt", "ota", "chk"):
                        v = d.get(kind)
                        if not v:
                            continue
                        if kind == "part":
                            total = sum(s for _, s, _ in v)
                            first = v[0][2]
                            chips.append(
                                f'<a class="chip img" href="{html.escape(first)}">镜像 ×{len(v)} 分片 · {human(total)}</a>')
                        else:
                            label = CHIP[kind] + (f" · {human(v[1])}" if kind in ("img", "ota") else "")
                            cls = "chip img" if kind in ("img", "ota") else "chip"
                            chips.append(f'<a class="{cls}" href="{html.escape(v[2])}">{html.escape(label)}</a>')
                    cards.append(f"""
        <div class="card">
          <div class="card-title">{title}</div>
          <div class="chips">{''.join(chips)}</div>
        </div>""")
        onedrive = meta.get("onedrive_url", "")
        od = (f'<a class="od" href="{html.escape(onedrive)}">OneDrive 镜像 →</a>' if onedrive else "")
        sec_html.append(f"""
    <section id="{html.escape(b)}">
      <h2>reComputer {html.escape(b)}</h2>
      {''.join(cards)}
      {od}
    </section>""")

    tag = html.escape(meta.get("tag", ""))
    date = html.escape(meta.get("generated_at", ""))
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Seeed reComputer — Armbian 镜像下载</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font: 15px/1.6 -apple-system, "Segoe UI", "Noto Sans SC", sans-serif;
         background: #0f172a; color: #e2e8f0; }}
  main {{ max-width: 880px; margin: 0 auto; padding: 40px 20px 80px; }}
  h1 {{ font-size: 24px; margin: 0 0 4px; }}
  .sub {{ color: #94a3b8; margin-bottom: 8px; }}
  .tag {{ display: inline-block; background: rgba(34,211,238,.15); color: #22d3ee;
          border: 1px solid rgba(34,211,238,.4); border-radius: 6px; padding: 1px 8px;
          font: 12px/1.6 ui-monospace, monospace; }}
  section {{ margin-top: 44px; }}
  h2 {{ font-size: 18px; border-bottom: 1px solid #1e293b; padding-bottom: 8px; }}
  .card {{ background: #131c31; border: 1px solid #1e293b; border-radius: 10px;
           padding: 12px 16px; margin: 12px 0; }}
  .card-title {{ font-weight: 600; margin-bottom: 6px; }}
  .chips {{ display: flex; flex-wrap: wrap; gap: 8px; }}
  .chip, .od {{ display: inline-block; padding: 3px 12px; border-radius: 999px;
          border: 1px solid #334155; color: #cbd5e1; text-decoration: none; font-size: 13px; }}
  .chip.img {{ border-color: rgba(52,211,153,.5); color: #34d399; }}
  .chip:hover, .od:hover {{ background: #1e293b; }}
  .od {{ margin-top: 10px; display: inline-block; border-color: rgba(96,165,250,.5); color: #60a5fa; }}
  footer {{ margin-top: 60px; color: #64748b; font-size: 13px; }}
  footer code {{ background: #1e293b; padding: 1px 6px; border-radius: 4px; }}
</style>
</head>
<body>
<main>
  <h1>Seeed reComputer — Armbian 镜像</h1>
  <div class="sub">当前正式版 <span class="tag">{tag}</span> · 生成于 {date}</div>
  {''.join(sec_html)}
  <footer>
    分片（&gt;2 GiB）下载后执行 <code>cat 文件名.*.part &gt; 文件名</code> 重组，再用同名 sha256 校验。<br>
    镜像写入：<code>xz -d -T0 xxx.img.xz</code> 后 <code>dd</code> / balenaEtcher 写入 eMMC/SD。
  </footer>
</main>
</body>
</html>
"""


def main():
    assets_tsv, meta_json = sys.argv[1], sys.argv[2]
    meta = json.load(open(meta_json))
    rows = defaultdict(dict)
    for line in open(assets_tsv):
        line = line.rstrip("\n")
        if not line:
            continue
        name, size, url = line.split("\t")
        r = parse(name, int(size), url)
        if not r:
            continue
        board, variant, mode, crypt, kind, name, size, url = r
        if kind == "part":
            rows[(board, variant, mode, crypt)].setdefault("part", []).append((name, size, url))
        else:
            rows[(board, variant, mode, crypt)][kind] = (name, size, url)
    print(render(dict(rows), meta))


if __name__ == "__main__":
    main()
