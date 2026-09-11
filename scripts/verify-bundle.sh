#!/bin/zsh
# Verifies that the bundled offline runtime actually contains every image the
# generated docker-compose.yml asks for, for both architectures.
#
# This exists because the two used to drift: composeFile pinned
# postgres:18-alpine / redis:8-alpine while the bundler saved 16-alpine /
# 7-alpine. Dev machines hid it (the tags were already in the local Docker
# cache); fresh installs hit a registry pull and failed to start Sub2API.
#
# Usage:
#   scripts/verify-bundle.sh                  # verify Resources/BundledRuntime
#   scripts/verify-bundle.sh dist/AgentHub.app  # verify a built .app bundle
set -euo pipefail

project_dir="${0:A:h:h}"
source_file="$project_dir/Sources/QuotaBar/Sub2APIServiceManager.swift"

target="${1:-}"
if [[ -n "$target" ]]; then
  runtime_dir="$target/Contents/Resources/BundledRuntime"
  label="$target"
else
  runtime_dir="$project_dir/Resources/BundledRuntime"
  label="Resources/BundledRuntime"
fi

# Ad hoc signatures cannot carry Apple's restricted application identity and
# keychain access-group entitlements. macOS rejects the process before launch
# when those entitlements are embedded without a real signing identity.
if [[ -n "$target" && -f "$target/Contents/MacOS/AgentHub" ]]; then
  signature_details="$(codesign -dv --verbose=4 "$target" 2>&1 || true)"
  if grep -q 'Signature=adhoc' <<<"$signature_details"; then
    entitlements="$(codesign -d --entitlements :- "$target" 2>/dev/null || true)"
    if grep -qE '<key>(com\.apple\.application-identifier|keychain-access-groups)</key>' <<<"$entitlements"; then
      echo "FAILED: ad hoc AgentHub signature contains restricted entitlements" >&2
      exit 1
    fi
  fi
fi

test -f "$source_file" || { echo "missing $source_file" >&2; exit 1 }
test -d "$runtime_dir" || { echo "missing $runtime_dir" >&2; exit 1 }

SOURCE_FILE="$source_file" RUNTIME_DIR="$runtime_dir" LABEL="$label" python3 - <<'PY'
import gzip, hashlib, io, json, os, re, subprocess, sys, tarfile, textwrap

source_file = os.environ["SOURCE_FILE"]
runtime_dir = os.environ["RUNTIME_DIR"]
label = os.environ["LABEL"]

swift = open(source_file, encoding="utf-8").read()
failures = []
notes = []

def fail(msg):
    failures.append(msg)
    print(f"  FAIL  {msg}")

def ok(msg):
    print(f"  ok    {msg}")

# ---- 1. what does the app ask Docker for? -------------------------------
pinned = re.search(r'pinnedVersion\s*=\s*"([^"]+)"', swift)
if not pinned:
    print("could not find pinnedVersion in Sub2APIServiceManager.swift", file=sys.stderr)
    sys.exit(1)
pinned = pinned.group(1)

compose = re.search(r'static let composeFile = """(.*?)"""', swift, re.S)
if not compose:
    print("could not find composeFile in Sub2APIServiceManager.swift", file=sys.stderr)
    sys.exit(1)
compose = compose.group(1)
expected_compose = textwrap.dedent(compose).strip("\n") + "\n"
bundled_compose_path = os.path.join(runtime_dir, "docker-compose.yml")
if label.endswith(".app"):
    if not os.path.exists(bundled_compose_path):
        fail("bundled docker-compose.yml missing")
    elif open(bundled_compose_path, encoding="utf-8").read() != expected_compose:
        fail("bundled docker-compose.yml differs from Sub2APIServiceManager.composeFile")
    else:
        ok("bundled docker-compose.yml exactly matches the app source")

required = set()
for image in re.findall(r'^\s*image:\s*(\S+)\s*$', compose, re.M):
    required.add(image.replace("${SUB2API_VERSION}", pinned))

print(f"verifying {label}")
print(f"compose requires: {', '.join(sorted(required))}")
print()

# ---- 2. what is actually in each tarball? -------------------------------
arch_alias = {"arm64": {"arm64"}, "x86_64": {"amd64"}}

for app_arch, want_arches in arch_alias.items():
    archive = os.path.join(runtime_dir, f"docker-images-{app_arch}.tar.gz")
    print(f"[{app_arch}] {os.path.basename(archive)}")
    if not os.path.exists(archive):
        fail(f"{app_arch}: archive missing")
        print()
        continue

    manifest = None
    small = {}
    config_sizes = {}
    # single streaming pass: keep manifest + every small blob (image configs)
    with gzip.open(archive, "rb") as gz:
        with tarfile.open(fileobj=gz, mode="r|") as tar:
            for member in tar:
                if not member.isfile():
                    continue
                if member.name == "manifest.json":
                    manifest = json.loads(tar.extractfile(member).read())
                else:
                    config_sizes[member.name] = member.size
                    if member.size <= 65536:
                        small[member.name] = tar.extractfile(member).read()

    if manifest is None:
        fail(f"{app_arch}: no manifest.json in archive")
        print()
        continue

    present = set()
    tag_counts = {}
    for entry in manifest:
        tags = entry.get("RepoTags") or []
        if not tags:
            fail(f"{app_arch}: archive contains an untagged image entry")
        for tag in tags:
            present.add(tag)
            tag_counts[tag] = tag_counts.get(tag, 0) + 1

    missing = required - present
    extra = present - required
    if missing:
        fail(f"{app_arch}: compose needs {sorted(missing)} but the archive does not contain them")
    else:
        ok(f"{app_arch}: all {len(required)} required images present")
    if extra:
        fail(f"{app_arch}: archive carries unused images {sorted(extra)}")
    duplicated = sorted(tag for tag, count in tag_counts.items() if count != 1)
    if duplicated:
        fail(f"{app_arch}: image tags are not mapped exactly once: {duplicated}")

    # every image must be built for the architecture this archive targets
    arch_clean = True
    for entry in manifest:
        tags = entry.get("RepoTags") or ["<untagged>"]
        blob = small.get(entry["Config"])
        if blob is None:
            arch_clean = False
            size = config_sizes.get(entry["Config"])
            detail = "missing" if size is None else f"{size} bytes"
            fail(f"{app_arch}: config blob missing or too large for {tags[0]} ({detail})")
            continue
        got = json.loads(blob).get("architecture")
        if got not in want_arches:
            arch_clean = False
            fail(f"{app_arch}: {tags[0]} is architecture={got}, expected {'/'.join(want_arches)}")
    if arch_clean:
        ok(f"{app_arch}: every image built for {'/'.join(want_arches)}")
    print()

# ---- 3. codex binaries --------------------------------------------------
print("[codex]")
expected_codex_sha256 = {
    "arm64": "f4a74117b8142cda581c95ff753abf4508b5636d89682c1ed77e4a9249af8963",
    "x86_64": "c646bd178240bb50efd81c2f9919dd9124b126c815911f6c1b6db400786c5ccd",
}
for app_arch, want in (("arm64", "arm64"), ("x86_64", "x86_64")):
    binary = os.path.join(runtime_dir, app_arch, "codex")
    if not os.path.exists(binary):
        fail(f"codex/{app_arch}: missing")
        continue
    if not os.access(binary, os.X_OK):
        fail(f"codex/{app_arch}: not executable")
    archs = subprocess.run(["/usr/bin/lipo", "-archs", binary],
                           capture_output=True, text=True).stdout.split()
    if want not in archs:
        fail(f"codex/{app_arch}: binary is {archs}, expected {want}")
    else:
        ok(f"codex/{app_arch}: {' '.join(archs)}")
    digest = hashlib.sha256()
    with open(binary, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_codex_sha256[app_arch]:
        fail(f"codex/{app_arch}: SHA-256 does not match the pinned Codex 0.149.0 binary")
    else:
        ok(f"codex/{app_arch}: pinned Codex 0.149.0 SHA-256")
print()

# ---- 4. VERSIONS.txt must describe what is really shipped ---------------
print("[VERSIONS.txt]")
versions_path = os.path.join(runtime_dir, "VERSIONS.txt")
if not os.path.exists(versions_path):
    fail("VERSIONS.txt missing")
else:
    versions = open(versions_path, encoding="utf-8").read()
    claimed = {}
    for line in versions.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            claimed[k.strip()] = v.strip()
    expect = {}
    expect["OpenAI Codex CLI"] = "0.149.0"
    for image in required:
        repo, _, tag = image.rpartition(":")
        if repo == "postgres":
            expect["PostgreSQL"] = tag
        elif repo == "redis":
            expect["Redis"] = tag
        elif repo.endswith("sub2api"):
            expect["Sub2API"] = tag
    for key, want in sorted(expect.items()):
        got = claimed.get(key)
        if got != want:
            fail(f"VERSIONS.txt says {key}={got!r}, compose uses {want!r}")
        else:
            ok(f"{key} = {want}")
print()

for note in notes:
    print(f"  note  {note}")
if notes:
    print()

if failures:
    print(f"FAILED ({len(failures)} problem{'s' if len(failures) != 1 else ''})")
    sys.exit(1)
print("OK — bundled runtime matches the compose file the app generates")
PY
