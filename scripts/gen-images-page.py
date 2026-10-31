#!/usr/bin/env python3
"""Generate the images download page (static HTML) from release assets.

Style: Seeed Studio brand palette on an armbian.com board-page layout
(product photo + labeled download rows). Brand colors taken from
seeedstudio.com CSS: green #8dc215 (primary), deep teal #03353f,
orange #ffbc44 (accent), light grays.

Input:
  assets.tsv   — "name<TAB>size<TAB>url" per line (gh release view --json assets)
  meta.json    — {"tag": ..., "generated_at": ..., "onedrive_url": ...}
Output: standalone HTML on stdout (no external deps; board photos are
hotlinked from armbian.com's public image API).

Filename grammar (armbian image names self-describe everything):
  …_Recomputer-<board>_<release>_vendor_<kernel>_<variant>[_AB_PART|-crypt].…
    board   — captured verbatim (rk3576-devkit, rk3576-industrial, …)
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

GREEN, TEAL, ORANGE = "#8dc215", "#03353f", "#ffbc44"


def board_image(board):
    # armbian.com names the module image …-module-devkit (no inner dash)
    b = board.replace("-dev-kit", "-devkit")
    return f"https://armbian.com/api/v1/images/boards/480/recomputer-{b}.png"


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
        kind = "sha256"
    if kind is None:
        return None
    return board, variant, mode, crypt, kind, name, size, url


def human(n):
    n = float(n)
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return f"{int(n)}{unit}" if unit in ("B", "K") else f"{n:.1f}{unit}"
        n /= 1024


VARIANT_TITLE = {"cli": "CLI", "desktop": "桌面"}
ROW_LABEL = {"img": "镜像", "part": "镜像（分片）", "ota": "OTA 包",
             "sha256": "sha256", "sha": "sha", "chk": "校验", "txt": "构建信息"}


def links_html(d):
    out = []
    for kind in ("img", "part", "ota", "sha256", "sha", "chk", "txt"):
        v = d.get(kind)
        if not v:
            continue
        primary = kind in ("img", "part", "ota")
        if kind == "part":
            total = sum(s for _, s, _ in v)
            href, label = v[0][2], f"{ROW_LABEL[kind]} ×{len(v)} · {human(total)}"
        else:
            href, label = v[2], ROW_LABEL[kind] + (f" · {human(v[1])}" if primary else "")
        cls = "btn primary" if primary else "btn"
        out.append(f'<a class="{cls}" href="{html.escape(href)}">{html.escape(label)}</a>')
    return "".join(out)


def render(rows, meta):
    boards = sorted({k[0] for k in rows})
    sections = []
    for b in boards:
        dl_rows = []
        for variant in ("cli", "desktop"):
            for mode in ("recovery", "ab"):
                for crypt in (False, True):
                    d = rows.get((b, variant, mode, crypt))
                    if not d:
                        continue
                    badges = ""
                    if mode == "ab":
                        badges += '<span class="badge ab">A/B</span>'
                    if crypt:
                        badges += '<span class="badge crypt">加密</span>'
                    dl_rows.append(f"""
        <div class="row">
          <div class="row-title">{VARIANT_TITLE[variant]}{badges}</div>
          <div class="row-links">{links_html(d)}</div>
        </div>""")
        od = ""
        if meta.get("onedrive_url"):
            od = (f'<a class="onedrive" href="{html.escape(meta["onedrive_url"])}">'
                  f'☁ OneDrive 下载全部</a>')
        sections.append(f"""
  <section class="board">
    <div class="photo">
      <img src="{board_image(b)}" alt="reComputer {html.escape(b)}" loading="lazy"
           onerror="this.closest('.photo').classList.add('noimg')">
    </div>
    <div class="info">
      <h2>reComputer <span>{html.escape(b)}</span></h2>
      <div class="downloads">{''.join(dl_rows)}</div>
      {od}
    </div>
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
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font: 15px/1.65 -apple-system, "Segoe UI", "Noto Sans SC", sans-serif;
         background: #f3f5f8; color: {TEAL}; }}
  header {{ background: {TEAL}; color: #fff; padding: 34px 0 30px; }}
  header .bar {{ width: 56px; height: 5px; background: {GREEN}; border-radius: 3px;
                 margin-bottom: 16px; }}
  main {{ max-width: 920px; margin: 0 auto; padding: 0 20px; }}
  h1 {{ font-size: 26px; margin: 0 0 6px; letter-spacing: .5px; }}
  h1 em {{ color: {GREEN}; font-style: normal; }}
  .sub {{ color: #b9cdd4; font-size: 14px; }}
  .tag {{ display: inline-block; background: rgba(141,194,21,.18); color: {GREEN};
          border: 1px solid rgba(141,194,21,.55); border-radius: 6px; padding: 0 8px;
          font: 12px/1.7 ui-monospace, "SF Mono", monospace; }}
  .board {{ display: flex; gap: 26px; background: #fff; border-radius: 14px;
            padding: 24px; margin: 22px 0; box-shadow: 0 1px 4px rgba(3,53,63,.08); }}
  .photo {{ flex: 0 0 300px; }}
  .photo img {{ width: 100%; border-radius: 10px; background: #fff; mix-blend-mode: multiply; }}
  .photo.noimg {{ display: none; }}
  .info {{ flex: 1; min-width: 0; }}
  h2 {{ font-size: 20px; margin: 2px 0 14px; }}
  h2 span {{ color: {GREEN}; }}
  .row {{ display: flex; align-items: baseline; gap: 14px; padding: 9px 0;
          border-top: 1px solid #eef2f6; flex-wrap: wrap; }}
  .row-title {{ flex: 0 0 64px; font-weight: 600; font-size: 14px; }}
  .row-links {{ display: flex; flex-wrap: wrap; gap: 8px; }}
  .badge {{ font-size: 11px; border-radius: 4px; padding: 0 6px; margin-left: 6px;
            vertical-align: 2px; }}
  .badge.ab {{ background: rgba(255,188,68,.18); color: #b96e00; border: 1px solid rgba(255,188,68,.6); }}
  .badge.crypt {{ background: rgba(3,53,63,.08); color: {TEAL}; border: 1px solid rgba(3,53,63,.25); }}
  .btn {{ display: inline-block; padding: 3px 12px; border-radius: 999px; font-size: 13px;
          text-decoration: none; color: {TEAL}; border: 1px solid #d7dee5; background: #fff; }}
  .btn.primary {{ background: {GREEN}; border-color: {GREEN}; color: #fff; font-weight: 600; }}
  .btn:hover {{ filter: brightness(.96); }}
  .onedrive {{ display: inline-block; margin-top: 14px; text-decoration: none; font-size: 14px;
               color: {TEAL}; border: 1px dashed {GREEN}; border-radius: 8px; padding: 5px 14px; }}
  footer {{ margin: 40px 0 60px; color: #7b8fa0; font-size: 13px; line-height: 2; }}
  footer code {{ background: #e8edf2; padding: 1px 7px; border-radius: 4px; font-size: 12px; }}
  @media (max-width: 720px) {{ .board {{ flex-direction: column; }} .photo {{ flex: none; }} }}
</style>
</head>
<body>
<header><main>
  <div class="bar"></div>
  <h1>Seeed <em>reComputer</em> — Armbian 镜像</h1>
  <div class="sub">当前正式版 <span class="tag">{tag}</span> &nbsp;·&nbsp; {date}</div>
</main></header>
<main>
{''.join(sections)}
  <footer>
    分片（&gt;2 GiB）下载后：<code>cat 文件名.*.part &gt; 文件名</code> 重组，再用同名 sha256 校验。<br>
    写入 eMMC/SD：<code>xz -d -T0 xxx.img.xz</code> 后用 <code>dd</code> 或 balenaEtcher 烧写。
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
