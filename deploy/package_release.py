"""Package verified compiled artifacts; no compiler or dependency downloads."""
import hashlib
import shutil
import tarfile

def package_release(bundle, cache, arch):
    # A self-contained installer carries the compiled release; target hosts need no compiler.
    archive = cache / "release.tar.gz"
    with tarfile.open(archive, "w:gz") as t:
        t.add(bundle, arcname="release")
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    header = '''#!/bin/sh
    set -eu
    [ "$(uname -s)" = Linux ] || { echo 'Ubuntu 24.04 required' >&2; exit 1; }
    . /etc/os-release
    [ "$ID:$VERSION_ID" = ubuntu:24.04 ] || { echo 'Ubuntu 24.04 required' >&2; exit 1; }
    [ "$(uname -m)" = "@ARCH@" ] || { echo 'Wrong CPU architecture' >&2; exit 1; }
    task_dir=$(mktemp -d)
    trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
    tail -n +@LINE@ "$0" > "$task_dir/release.tar.gz"
    printf '%s  %s\n' '@HASH@' "$task_dir/release.tar.gz" | sha256sum -c -
    tar -xzf "$task_dir/release.tar.gz" -C "$task_dir"
    packages="python3 bubblewrap apparmor ca-certificates libgmp10 libnuma1 libffi8 libtinfo6 zlib1g libpq5 postgresql-16 postgresql-client-16"
    missing=""
    for package in $packages; do
        [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || missing="$missing $package"
    done
    if [ -n "$missing" ]; then
        sudo apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages
    fi
    sudo python3 "$task_dir/release/deploy/install.py" "$task_dir/release" "$@"
    exit 0
    '''
    header = header.rstrip() + "\n"
    header = header.replace("@LINE@", str(header.count("\n") + 1)).replace("@HASH@", archive_hash).replace("@ARCH@", arch)
    release = cache / f"ecx-bridge-ubuntu-24.04-{arch}.run"
    with release.open("wb") as f:
        f.write(header.encode())
        with archive.open("rb") as src:
            shutil.copyfileobj(src, f)
    release.chmod(0o755)
    release.with_suffix(".run.sha256").write_text(hashlib.sha256(release.read_bytes()).hexdigest() + "  " + release.name + "\n")
    print(f"One-command installer: {release}")
    return release
