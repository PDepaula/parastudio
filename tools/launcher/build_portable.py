#!/usr/bin/env python3
"""Assemble the portable Para Studio zip for Windows (docs/windows.md, "The portable zip").

    python tools/launcher/build_portable.py                 # build into tmp/portable/
    python tools/launcher/build_portable.py --plan          # print what it would fetch and build
    python tools/launcher/build_portable.py --check-zip Z   # check an existing zip's layout

The zip holds one folder, Paraloop-Studio/:

    Paraloop-Studio.exe     the native launcher (tools/launcher/launch.nim, compiled here)
    README.txt              three lines for the person who unpacks it
    nim-2.2.10/             Nim's own Windows release (nim-lang.org), checksum-checked
    mingw64/                the MinGW-w64 C compiler Nim's own installer uses (nim-lang.org), checksum-checked,
                            minus the parts a C build never runs (Fortran, D and Objective-C front ends, gdb, JIT)
    parastudio/             this repository at one exact commit, with its .git folder
    licenses/               what Nim and MinGW are licensed under, and the source offer for MinGW

Standard library only. Extracting the compiler needs 7-Zip (7z, on every GitHub Windows runner) or a
tar that reads .7z (libarchive's bsdtar, and the tar.exe that comes with Windows 10 and 11).

Nothing in it is downloaded when the friend runs it. Both downloads are pinned to a SHA-256 written
below (the one nim-lang.org published when it was pinned) and are also compared to the value
nim-lang.org publishes next to the file at download time; either differing stops the build. Run it
on Windows (the launcher is compiled with the Nim and C compiler on PATH and must be a Windows
program); `--launcher PATH` uses a program you already built instead, which is how the layout is
tried on another system. Signing is not done here: the workflow (.github/workflows/portable.yml)
compiles the launcher with `--launcher-only`, has a marked hook where it will be signed, and then
assembles with `--launcher` pointing at the signed program, so the signature is inside the zip.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

NIM_VERSION = "2.2.10"
NIM_ZIP_URL = f"https://nim-lang.org/download/nim-{NIM_VERSION}_x64.zip"
# SHA-256 of that zip, from the .sha256 file nim-lang.org publishes next to it (the same value pinned
# in tools/launcher/launch.bat; tests/test_portable.nim checks the two stay equal).
NIM_ZIP_SHA256 = "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"
MINGW_URL = "https://nim-lang.org/download/mingw64.7z"
# SHA-256 of that archive, from mingw64.7z.sha256 on nim-lang.org (checked 2026-11-03): the winlibs
# build "gcc-11.1.0-mingw-w64-8.0.2-r1" that Nim's finish.exe installs.
MINGW_SHA256 = "04a535d1e0880364ca9609713744f1a9a36835c4ced834cf435c4dc4eca2159a"
REPO_URL = "https://github.com/PDepaula/parastudio.git"
# What is deleted from mingw64/ after unpacking: front ends, a debugger and documentation a C build never
# uses (about 190 MB of the 600 MB). The portable workflow builds para with the result, so a wrong entry shows there.
MINGW_DROP = [
    "libexec/gcc/x86_64-w64-mingw32/11.1.0/f951.exe",
    "libexec/gcc/x86_64-w64-mingw32/11.1.0/d21.exe",
    "libexec/gcc/x86_64-w64-mingw32/11.1.0/cc1obj.exe",
    "libexec/gcc/x86_64-w64-mingw32/11.1.0/cc1objplus.exe",
    "bin/gdb.exe", "bin/gdbserver.exe", "bin/gdb-add-index", "bin/lto-dump.exe", "bin/libgccjit-0.dll",
    "bin/gfortran.exe", "bin/x86_64-w64-mingw32-gfortran.exe", "bin/gdc.exe", "bin/x86_64-w64-mingw32-gdc.exe",
    "bin/ccache.exe",
    "share/gdb", "share/man", "share/info",
]
FOLDER = "Paraloop-Studio"
EXE = "Paraloop-Studio.exe"

REQUIRED = [
    f"{FOLDER}/{EXE}",
    f"{FOLDER}/README.txt",
    f"{FOLDER}/nim-{NIM_VERSION}/bin/nim.exe",
    f"{FOLDER}/nim-{NIM_VERSION}/bin/nimble.exe",
    f"{FOLDER}/mingw64/bin/gcc.exe",
    f"{FOLDER}/parastudio/paraloop.nimble",
    f"{FOLDER}/parastudio/tools/para/para.nim",
    f"{FOLDER}/parastudio/.git/HEAD",
    f"{FOLDER}/licenses/NOTICES.txt",
]
# Never in the zip: the launcher must not offer a way to change PATH or machine settings.
FORBIDDEN = [f"{FOLDER}/nim-{NIM_VERSION}/finish.exe"]

README = """Para Studio, portable

1. Right-click this zip file, choose Extract All, and extract it to a SHORT folder such as C:\\ParaStudio
   (not into Downloads, and not into a folder inside another folder inside another).
2. Open the new folder and double-click Paraloop-Studio.exe.
3. If Windows says "Windows protected your PC", click More info, then Run anyway. This file is not
   signed yet; that is the only reason for the warning.

The first start takes several minutes (it fetches the game libraries and builds Studio). Later starts
take seconds. Everything it needs except git is in this folder; nothing is installed on your PC.
It asks before it installs anything (only git, and only if you do not have it), and never asks for an
administrator password. Full guide: parastudio\\docs\\windows.md
"""

NOTICES = """Para Studio portable zip: what is in it, under which terms

paraloop (parastudio\\) is MIT-licensed: parastudio\\LICENSE. Its libraries are listed in
parastudio\\THIRD_PARTY.md; nimble fetches them the first time you start it.

Nim {nim} (nim-{nim}\\), the compiler: MIT, nim-{nim}\\copying.txt. Unmodified, from
{nim_url}

MinGW-w64 (mingw64\\), the C compiler Nim's own Windows installer sets up: the winlibs build
gcc-11.1.0-mingw-w64-8.0.2-r1 (GCC 11.1.0, binutils 2.36.1, mingw-w64 8.0.2, GDB 10.2, GNU Make 4.3
and others), unmodified, from
{mingw_url}
GCC, binutils, GDB and Make are free software under the GNU General Public License (version 3 or
later; GCC also under the GCC Runtime Library Exception, which lets the programs it builds be
licensed as their authors choose). The corresponding source code is published by the winlibs
project (https://github.com/brechtsanders/winlibs_mingw) and by each project (https://gcc.gnu.org,
https://www.gnu.org/software/binutils/, https://www.mingw-w64.org). If you cannot get it from
there, ask the person who gave you this zip and it will be sent to you.
""".format(nim=NIM_VERSION, nim_url=NIM_ZIP_URL, mingw_url=MINGW_URL)


def say(msg: str = "") -> None:
    print(msg, flush=True)


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def open_url(url: str, timeout: int):
    """urlopen with a plain User-Agent: nim-lang.org refuses Python's default one (HTTP 403)."""
    req = urllib.request.Request(url, headers={"User-Agent": "paraloop-portable-build (+https://github.com/PDepaula/parastudio)"})
    try:
        return urllib.request.urlopen(req, timeout=timeout)  # noqa: S310 (https, fixed URL)
    except OSError as e:
        die(f"could not download {url}: {e}")


def fetch(url: str, pinned: str, cache: Path) -> Path:
    """Download `url` into `cache` (reusing a copy that already matches), refusing any file whose
    SHA-256 is not the pinned one or not the one published next to it."""
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / url.rsplit("/", 1)[1]
    if not (dest.exists() and sha256_of(dest) == pinned):
        say(f"  downloading {url}")
        tmp = dest.with_suffix(dest.suffix + ".part")
        with open_url(url, 120) as r, tmp.open("wb") as f:
            shutil.copyfileobj(r, f)
        tmp.replace(dest)
    actual = sha256_of(dest)
    with open_url(url + ".sha256", 60) as r:
        published = r.read().decode().split()[0].lower()
    say(f"  sha256 {actual} (pinned {pinned}, published {published})")
    if actual != pinned or actual != published:
        dest.unlink(missing_ok=True)
        die(f"{url} does not match its checksum; it was NOT used. computed {actual}, pinned {pinned}, nim-lang.org publishes {published}")
    return dest


def git(*args: str, cwd: Path | None = None) -> str:
    # Line endings are never converted: the zip's copy is the repository's bytes, so `git status` in
    # it is clean whatever the friend's own git setting is.
    cmd = ["git", "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "advice.detachedHead=false", *args]
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def build_launcher(out: Path, cache: Path) -> Path:
    """Compile tools/launcher/launch.nim into `out` with the Nim on PATH."""
    nim = shutil.which("nim")
    if not nim:
        die("nim is not on PATH, so the launcher cannot be compiled. Install Nim 2.2.10, or pass --launcher PATH.")
    version = subprocess.run([nim, "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    if f"Version {NIM_VERSION} " not in version:
        die(f"the Nim on PATH is not {NIM_VERSION} ({version})")
    say(f"  compiling tools/launcher/launch.nim with: {version}")
    cmd = [nim, "c", "-d:release", "--opt:size", "--hints:off", "--skipParentCfg", "--skipProjCfg", "--mm:orc",
           f"--nimcache:{cache / 'nimcache'}", f"--out:{out}", str(ROOT / "tools" / "launcher" / "launch.nim")]
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0 or not out.exists():
        die("compiling the launcher failed")
    return out


def extract_nim(zip_path: Path, dest: Path) -> None:
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(dest)
    if not (dest / f"nim-{NIM_VERSION}" / "bin" / "nim.exe").exists():
        die(f"the Nim zip did not hold nim-{NIM_VERSION}/bin/nim.exe")
    for name in ("finish.exe",):
        (dest / f"nim-{NIM_VERSION}" / name).unlink(missing_ok=True)


def extract_mingw(archive: Path, dest: Path) -> None:
    """Unpack the .7z with 7-Zip when there is one, else with a tar that reads 7z, then drop MINGW_DROP."""
    seven = next((p for p in (shutil.which("7z"), shutil.which("7zz"), shutil.which("7za"),
                              r"C:\Program Files\7-Zip\7z.exe") if p and Path(p).exists()), None)
    if seven:
        cmd = [seven, "x", "-y", f"-o{dest}", str(archive)]
    else:
        # Windows' own tar.exe is libarchive's; on a runner `tar` can be Git's GNU tar, which cannot read .7z
        tar = shutil.which("bsdtar") or next((p for p in (os.path.join(os.environ.get("SystemRoot", ""), "System32", "tar.exe"),) if os.path.exists(p)), None) or shutil.which("tar")
        if not tar:
            die("neither 7-Zip nor a tar was found to unpack the MinGW archive")
        cmd = [tar, "-xf", str(archive), "-C", str(dest)]
    say(f"  unpacking with {Path(cmd[0]).name}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"unpacking the MinGW archive failed ({' '.join(cmd[:2])}): {(r.stdout + r.stderr).strip()[-600:]}")
    mingw = dest / "mingw64"
    if not (mingw / "bin" / "gcc.exe").exists():
        die("the MinGW archive did not hold mingw64/bin/gcc.exe")
    freed = 0
    for rel in MINGW_DROP:
        f = mingw / rel
        if f.is_dir():
            freed += sum(x.stat().st_size for x in f.rglob("*") if x.is_file())
            shutil.rmtree(f)
        elif f.exists():
            freed += f.stat().st_size
            f.unlink()
    say(f"  dropped front ends, debugger and docs a C build never uses ({freed // (1 << 20)} MB)")


def checkout_repo(dest: Path, commit: str) -> str:
    """The repository at exactly `commit`, history included, on a branch called main, origin pointing
    at the public repository, no line endings changed."""
    sha = git("rev-parse", "--verify", f"{commit}^{{commit}}", cwd=ROOT)
    dest.mkdir(parents=True)
    git("init", "-q", "-b", "main", str(dest))
    git("fetch", "-q", "--no-tags", str(ROOT), sha, cwd=dest)
    git("checkout", "-q", "-B", "main", "FETCH_HEAD", cwd=dest)
    git("remote", "add", "origin", REPO_URL, cwd=dest)
    git("config", "core.autocrlf", "false", cwd=dest)
    git("config", "core.fileMode", "false", cwd=dest)  # a zip carries no Unix modes; Git for Windows has it off too
    if git("rev-parse", "HEAD", cwd=dest) != sha:
        die("the copy is not at the commit asked for")
    if git("status", "--porcelain", cwd=dest):
        die("the fresh copy has changed files")
    return sha


def write_zip(src: Path, dest: Path, epoch: int) -> None:
    """Zip `src` (a folder) with its own name as the top folder, in a fixed order with a fixed time
    so the same inputs give the same bytes."""
    stamp = max(epoch, 315532800)  # zip cannot hold dates before 1980
    t = time.gmtime(stamp)[:6]
    entries = sorted(p for p in src.rglob("*") if not p.is_symlink())
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        for p in [src, *entries]:
            name = p.relative_to(src.parent).as_posix()
            if p.is_dir():
                zi = zipfile.ZipInfo(name + "/", t)
                zi.external_attr = 0o40755 << 16
                z.writestr(zi, b"")
            else:
                zi = zipfile.ZipInfo(name, t)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = (0o100000 | (p.stat().st_mode & 0o777)) << 16
                with p.open("rb") as f:
                    z.writestr(zi, f.read(), compresslevel=6)


def check_zip(path: Path) -> list[str]:
    """Findings (empty when the zip has the layout the launcher expects)."""
    findings: list[str] = []
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            bad = z.testzip()
    except zipfile.BadZipFile as e:
        return [f"{path} is not a readable zip: {e}"]
    if bad:
        findings.append(f"a damaged entry: {bad}")
    for need in REQUIRED:
        if need not in names:
            findings.append(f"missing: {need}")
    for no in FORBIDDEN:
        if no in names:
            findings.append(f"must not be in the zip: {no}")
    tops = {n.split("/", 1)[0] for n in names}
    if tops != {FOLDER}:
        findings.append(f"the zip must hold one top folder, {FOLDER}/; it holds {sorted(tops)}")
    return findings


def plan() -> None:
    say("Portable zip plan")
    say(f"  folder:    {FOLDER}/")
    say(f"  launcher:  tools/launcher/launch.nim compiled with the Nim on PATH, as {EXE}")
    say(f"  Nim:       {NIM_ZIP_URL}  sha256 {NIM_ZIP_SHA256}")
    say(f"  MinGW:     {MINGW_URL}  sha256 {MINGW_SHA256}")
    say(f"  checkout:  this repository at the commit given by --commit (default HEAD), origin {REPO_URL}")
    say("  zip:       Paraloop-Studio-<commit>-windows-x64.zip and its .sha256, in --out")


def main() -> None:
    ap = argparse.ArgumentParser(description="Assemble the portable Para Studio zip for Windows.")
    ap.add_argument("--out", type=Path, default=ROOT / "tmp" / "portable", help="where the zip and its checksum go (default tmp/portable)")
    ap.add_argument("--cache", type=Path, default=ROOT / "tmp" / "portable-cache", help="where downloads are kept (default tmp/portable-cache)")
    ap.add_argument("--commit", default="HEAD", help="the commit of this repository to put in the zip (default HEAD)")
    ap.add_argument("--launcher", type=Path, help="use this already-built (and, once signing exists, already signed) launcher program instead of compiling one")
    ap.add_argument("--launcher-only", type=Path, metavar="EXE", help="compile the launcher to EXE and stop (the workflow signs it, then runs this script again with --launcher)")
    ap.add_argument("--plan", action="store_true", help="print what would be fetched and built, and stop")
    ap.add_argument("--check-zip", type=Path, metavar="ZIP", help="check an existing zip's layout and stop")
    a = ap.parse_args()

    if a.plan:
        plan()
        return
    if a.check_zip:
        found = check_zip(a.check_zip)
        for f in found:
            say(f"finding: {f}")
        if found:
            raise SystemExit(1)
        say(f"{a.check_zip}: layout ok")
        return

    if a.launcher_only:
        a.launcher_only.parent.mkdir(parents=True, exist_ok=True)
        build_launcher(a.launcher_only.resolve(), a.cache)
        say(f"built {a.launcher_only}")
        return

    plan()
    a.out.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix="paraloop-portable-", dir=a.out))
    try:
        stage = stage_root / FOLDER
        stage.mkdir()
        say("Launcher")
        exe = a.launcher if a.launcher else build_launcher(stage_root / EXE, a.cache)
        if not exe.exists():
            die(f"{exe} does not exist")
        shutil.copy2(exe, stage / EXE)
        say("Nim")
        extract_nim(fetch(NIM_ZIP_URL, NIM_ZIP_SHA256, a.cache), stage)
        say("MinGW")
        extract_mingw(fetch(MINGW_URL, MINGW_SHA256, a.cache), stage)
        say("Para Studio")
        sha = checkout_repo(stage / "parastudio", a.commit)
        say(f"  at commit {sha}")
        (stage / "licenses").mkdir()
        (stage / "licenses" / "NOTICES.txt").write_text(NOTICES.replace("\n", "\r\n"), newline="")
        (stage / "README.txt").write_text(README.replace("\n", "\r\n"), newline="")
        epoch = int(git("show", "-s", "--format=%ct", sha, cwd=ROOT))
        name = f"Paraloop-Studio-{sha[:10]}-windows-x64"
        zip_path = a.out / f"{name}.zip"
        say("Zip")
        write_zip(stage, zip_path, epoch)
        found = check_zip(zip_path)
        if found:
            die("the zip's layout is wrong: " + "; ".join(found))
        digest = sha256_of(zip_path)
        (a.out / f"{name}.zip.sha256").write_text(f"{digest}  {name}.zip\n")
        (a.out / f"{name}.json").write_text(json.dumps({
            "zip": f"{name}.zip", "sha256": digest, "commit": sha, "nim": NIM_VERSION,
            "nim_sha256": NIM_ZIP_SHA256, "mingw_sha256": MINGW_SHA256, "size": zip_path.stat().st_size,
            "signed": False,
        }, indent=2) + "\n")
        say(f"built {zip_path} ({zip_path.stat().st_size // (1 << 20)} MB)")
        say(f"sha256 {digest}")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"zip={zip_path}\nname={name}\nsha256={digest}\ncommit={sha}\n")
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


if __name__ == "__main__":
    main()
