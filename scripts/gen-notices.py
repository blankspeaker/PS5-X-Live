#!/usr/bin/env python3
"""Regenerates ThirdPartyLicenses/ and THIRD_PARTY_NOTICES.md from build/runtime.
Usage: scripts/gen-notices.py FFMPEG_SRC_DIR PBS_LICENSES_DIR PBS_LICENSE_FILE"""
import json, os, re, shutil, subprocess, sys, urllib.request
from email.parser import Parser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RT = os.path.join(ROOT, "build", "runtime")
OUT = os.path.join(ROOT, "ThirdPartyLicenses")
ff_src, pbs_lic, pbs_license = sys.argv[1:4]

def sh(*a): return subprocess.check_output(a, text=True)
build = open(os.path.join(ROOT, "scripts", "build-runtime.sh")).read()
var = lambda n: re.search(rf"(?<![A-Za-z_]){n}=([^\s;]+)", build).group(1)
FFVER, FFSHA, PBS, PYVER = var("FFVER"), var("FFSHA"), var("PBS"), var("PYVER")
PYSHA = var("PYSHA")

shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)
rows, sections = [], []

# FFmpeg
d = os.path.join(OUT, "ffmpeg"); os.makedirs(d)
for f in ("COPYING.LGPLv2.1", "LICENSE.md"): shutil.copy(os.path.join(ff_src, f), d)
conf = sh(os.path.join(RT, "bin", "ffmpeg"), "-hide_banner", "-buildconf")
open(os.path.join(d, "BUILDCONF.txt"), "w").write(conf)
ffurl = f"https://ffmpeg.org/releases/ffmpeg-{FFVER}.tar.xz"
rows.append(("FFmpeg", FFVER, "LGPL-2.1-or-later", "https://ffmpeg.org", ffurl, FFSHA))
sections.append(f"""### FFmpeg {FFVER}

Bundled as a separate executable (`Contents/Resources/runtime/bin/ffmpeg`), not linked into the app.
Built by `scripts/build-runtime.sh` from the unmodified official source tarball with only LGPL components
(no `--enable-gpl`, no `--enable-nonfree`). The exact configure flags are in
[`ThirdPartyLicenses/ffmpeg/BUILDCONF.txt`](ThirdPartyLicenses/ffmpeg/BUILDCONF.txt).

- Source: {ffurl} (SHA-256 `{FFSHA}`, signature {ffurl}.asc)
- License: [LGPL-2.1-or-later](ThirdPartyLicenses/ffmpeg/COPYING.LGPLv2.1)

The corresponding source is the tarball above plus `scripts/build-runtime.sh` in this repository. If that
link stops working, open an issue in this repository and the source will be provided.
""")

# Python
d = os.path.join(OUT, "python"); os.makedirs(d)
for f in sorted(os.listdir(pbs_lic)):
    if f not in ("LICENSE.libX11.txt", "LICENSE.libXau.txt", "LICENSE.libxcb.txt", "LICENSE.tix.txt"):
        shutil.copy(os.path.join(pbs_lic, f), d)
shutil.copy(pbs_license, os.path.join(d, "LICENSE.python-build-standalone.txt"))
base = f"https://github.com/astral-sh/python-build-standalone/releases/download/{PBS}"
f = f"cpython-{PYVER}+{PBS}-aarch64-apple-darwin-install_only.tar.gz"
rows.append((f"CPython (python-build-standalone {PBS})", PYVER, "PSF-2.0", "https://www.python.org",
             f"{base}/{f.replace('+', '%2B')}", PYSHA))
comp = ", ".join(sorted(x[len("LICENSE."):-4] for x in os.listdir(d) if x.startswith("LICENSE.")))
sections.append(f"""### CPython {PYVER} (python-build-standalone {PBS})

Relocatable CPython builds from [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(MPL-2.0 build scripts). Unused parts are removed (Tcl/Tk, tests, IDLE, pip). The interpreter includes these
statically linked libraries, each with its license in [`ThirdPartyLicenses/python`](ThirdPartyLicenses/python): {comp}.

- CPython license: [PSF-2.0](ThirdPartyLicenses/python/LICENSE.cpython.txt)
- CPython source: https://www.python.org/ftp/python/{PYVER}/Python-{PYVER}.tar.xz
""")

# Python packages
req = open(os.path.join(ROOT, "scripts", "requirements-runtime.txt")).read()
pins = dict(re.findall(r"^([A-Za-z0-9_.-]+)==\S+ --hash=sha256:([0-9a-f]+)", req, re.M))
site = os.path.join(RT, "site")
pk = os.path.join(OUT, "python-packages"); os.makedirs(pk)
for di in sorted(os.listdir(site), key=str.lower):
    if not di.endswith(".dist-info"): continue
    meta = Parser().parsestr(open(os.path.join(site, di, "METADATA"), encoding="utf-8").read())
    name, ver = meta["Name"], meta["Version"]
    lic = meta.get("License-Expression") or meta.get("License") or ""
    lic = lic.splitlines()[0] if lic else ""
    fixes = {"isodate": "BSD-3-Clause", "trio-websocket": "MIT", "sortedcontainers": "Apache-2.0",
             "PySocks": "BSD-3-Clause", "pycryptodome": "BSD-2-Clause AND Public Domain"}
    lic = fixes.get(name, lic)
    home = meta.get("Home-page") or ""
    for u in meta.get_all("Project-URL") or []:
        k, _, v = u.partition(", ")
        if k.lower() in ("source", "source code", "code", "repository", "homepage") and not home: home = v
    j = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{ver}/json"))
    want = next(v for k, v in pins.items() if k.lower().replace("_", "-") == name.lower().replace("_", "-"))
    whl = next(u for u in j["urls"] if u["digests"]["sha256"] == want)
    sdist = next((u["url"] for u in j["urls"] if u["packagetype"] == "sdist"), "")
    home = home or j["info"].get("home_page") or f"https://pypi.org/project/{name}/"
    dd = os.path.join(pk, name); os.makedirs(dd)
    src = os.path.join(site, di)
    files = [os.path.join(r, f) for r, _, fs in os.walk(src) for f in fs
             if re.match(r"(LICEN[CS]E|COPYING|NOTICE|AUTHORS)", f, re.I)]
    for f in files: shutil.copy(f, dd)
    rows.append((name, ver, lic, home, whl["url"], want))
    note = " Translation files (`locales/`) are omitted." if name == "pycountry" else ""
    sections.append(f"""### {name} {ver}

- License: {lic} ([license files](ThirdPartyLicenses/python-packages/{name}))
- Upstream: {home}
- Wheel used: {whl['url']} (SHA-256 `{want}`)
- Source: {sdist or whl['url']}{note}
""")

md = ["# Third-party notices", "",
      "PS5 X Live bundles the components below inside `PS5 X Live.app/Contents/Resources/runtime`. "
      "Their license texts are in [`ThirdPartyLicenses/`](ThirdPartyLicenses) here and in "
      "`Contents/Resources/ThirdPartyLicenses` in the app. They run as separate processes; none is linked into the app binary.", "",
      "| Component | Version | License | Upstream | Download used | SHA-256 |", "| --- | --- | --- | --- | --- | --- |"]
md += [f"| {n} | {v} | {l} | {h} | [link]({u}) | `{s[:12]}…` |" for n, v, l, h, u, s in rows]
md += ["", "## Details", ""] + sections
md += ["## Trademarks", "", "PlayStation and PS5 are trademarks of Sony Interactive Entertainment. Twitch is a trademark of Twitch Interactive. "
       "X is a trademark of X Corp. This project is not affiliated with, endorsed by, or sponsored by any of them.", ""]
open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "w").write("\n".join(md))
print(len(rows), "components")
