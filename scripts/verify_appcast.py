#!/usr/bin/env python3
"""Pre-publish checks on a generated Sparkle appcast.

Every failure mode this catches is SILENT in production: the release builds, signs,
notarizes and uploads fine, and existing users simply are never offered it. There is
no error anywhere for you to notice.

    scripts/verify_appcast.py \
        --appcast docs/appcast.xml \
        --assets build/appcast-assets \
        --version 1.1.0              # optional; else the newest entry is assumed
        --build 7                    # optional; else the newest entry is assumed
        --public-key <base64>        # defaults to SUPublicEDKey from Info.plist
        --tag v1.1.0                 # optional; checks the download URL points at it

Exit code 0 = safe to publish.
"""
import argparse
import base64
import os
import pathlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ROOT = pathlib.Path(__file__).resolve().parent.parent

problems = []
notes = []


def fail(msg):
    problems.append(msg)


def ok(msg):
    notes.append(msg)


def ed25519_verify(pub_b64, sig_b64, payload: pathlib.Path) -> bool:
    """Verify a Sparkle edSignature over a file, via openssl.

    Sparkle signs the raw enclosure bytes with Ed25519. openssl needs an SPKI-wrapped
    key, which for Ed25519 is a fixed 12-byte prefix plus the 32 raw key bytes.
    """
    try:
        raw = base64.b64decode(pub_b64, validate=True)
        sig = base64.b64decode(sig_b64, validate=True)
    except Exception:
        return False
    if len(raw) != 32 or len(sig) != 64:
        return False
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        (td / "pub.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + raw)
        (td / "sig.bin").write_bytes(sig)
        if subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER",
                           "-in", td / "pub.der", "-out", td / "pub.pem"],
                          capture_output=True).returncode != 0:
            return False
        r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin",
                            "-inkey", td / "pub.pem", "-rawin",
                            "-in", payload, "-sigfile", td / "sig.bin"],
                           capture_output=True)
        return r.returncode == 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", default="docs/appcast.xml")
    p.add_argument("--assets", default="build/appcast-assets")
    # Optional: when omitted the newest appcast entry is taken as the release under
    # test. CI generates the appcast from whatever DMG the release carries, so there is
    # nothing independent to compare against there -- the relative checks (build must
    # increase, signature must verify) are the ones that matter.
    p.add_argument("--version", default=None)
    p.add_argument("--build", default=None)
    p.add_argument("--public-key", default=None)
    p.add_argument("--tag", default=None)
    a = p.parse_args()

    appcast = pathlib.Path(a.appcast)
    if not appcast.is_file():
        print(f"FATAL: no appcast at {appcast}")
        return 1

    pub = a.public_key
    if not pub:
        plist = ROOT / "ImmiBridge/ImmiBridge/UI/Info.plist"
        pub = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :SUPublicEDKey", str(plist)],
                             capture_output=True, text=True).stdout.strip()
    if not pub:
        print("FATAL: no public key (pass --public-key or set SUPublicEDKey in Info.plist)")
        return 1

    items = ET.parse(appcast).getroot().findall("./channel/item")
    if not items:
        print("FATAL: appcast has no items")
        return 1

    def build_of(item):
        el = item.find(f"{{{SPARKLE_NS}}}version")
        try:
            return int((el.text or "").strip())
        except (AttributeError, ValueError):
            return None

    top = items[0]
    top_build = build_of(top)
    top_short = top.findtext(f"{{{SPARKLE_NS}}}shortVersionString", "").strip()

    # 1. The new release must actually be the newest entry.
    if a.version is None:
        ok(f"newest entry is {top_short} (no --version given; taking it as the release)")
    elif top_short != a.version:
        fail(f"newest appcast entry is {top_short!r}, expected {a.version!r}")
    else:
        ok(f"newest entry is {a.version}")

    # 2. Sparkle compares CFBundleVersion, NOT the marketing version. If this does not
    #    strictly increase, every existing install sees 'no update available'.
    if top_build is None:
        fail("newest entry has no parseable <sparkle:version>")
    elif a.build is not None and str(top_build) != str(a.build):
        fail(f"newest entry has build {top_build}, expected {a.build}")
    else:
        others = [b for b in (build_of(i) for i in items[1:]) if b is not None]
        if others and top_build <= max(others):
            fail(f"build {top_build} is not greater than previous release build {max(others)} "
                 f"-- Sparkle will NOT offer this update to anyone")
        else:
            ok(f"build {top_build} > previous {max(others) if others else 'n/a'}")

    # 3. Duplicate build numbers across entries are always a mistake.
    seen = [build_of(i) for i in items]
    dupes = {b for b in seen if b is not None and seen.count(b) > 1}
    if dupes:
        fail(f"duplicate <sparkle:version> values in appcast: {sorted(dupes)}")

    enc = top.find("enclosure")
    if enc is None:
        fail("newest entry has no <enclosure>")
        return report()

    url = enc.get("url", "")
    if a.tag and f"/{a.tag}/" not in url:
        fail(f"enclosure url does not point at tag {a.tag}: {url}")
    elif a.tag:
        ok(f"enclosure url points at {a.tag}")

    # 4. The signature must verify against the key ACTUALLY SHIPPED in the app. A
    #    mismatch here means the update downloads and is then silently rejected.
    sig = enc.get(f"{{{SPARKLE_NS}}}edSignature")
    if not sig:
        fail("enclosure has no sparkle:edSignature")
    else:
        local = pathlib.Path(a.assets) / os.path.basename(url)
        if not local.is_file():
            fail(f"cannot verify signature: {local} not found (pass --assets)")
        else:
            declared = enc.get("length")
            actual = local.stat().st_size
            if declared and str(actual) != str(declared):
                fail(f"enclosure length {declared} != actual {actual} bytes")
            else:
                ok(f"enclosure length matches ({actual} bytes)")
            if ed25519_verify(pub, sig, local):
                ok("edSignature verifies against the app's SUPublicEDKey")
            else:
                fail("edSignature does NOT verify against the app's SUPublicEDKey -- "
                     "every client will download the update and then refuse to install it")

    return report()


def report():
    for n in notes:
        print(f"  ok    {n}")
    for pr in problems:
        print(f"  FAIL  {pr}")
    if problems:
        print(f"\nappcast verification FAILED ({len(problems)} problem(s)) -- do not publish")
        return 1
    print("\nappcast verification passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
