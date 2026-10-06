#!/usr/bin/env python3
"""Install the unpublished candidate through mise's GitHub backend in isolation."""

import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading

import publish_release
import release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("--mise", default="mise")
    args = parser.parse_args()
    archive = args.release_dir.resolve() / release.ARCHIVE
    with tarfile.open(archive, "r:gz") as contents:
        manifest = json.load(contents.extractfile("manifest.json"))
    publish_release.verify_assets(archive.parent, manifest["version"])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(archive.parent))
    with tempfile.TemporaryDirectory(prefix="custom-service-mise-") as directory, \
            http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        root = Path(directory)
        environment = dict(os.environ, MISE_YES="1", **{
            f"MISE_{kind.upper()}_DIR": str(root / kind) for kind in ("config", "data", "cache", "state")
        })
        # The explicit candidate URL exercises the real GitHub backend before publication.
        url = f"http://127.0.0.1:{server.server_port}/{archive.name}"
        (root / "mise.toml").write_text(
            '[tools."github:lynnswap/swift-build"]\n'
            f'version = {json.dumps(manifest["version"].removeprefix("v"))}\n'
            'bin_path = "bin"\nstrip_components = 0\n'
            f'checksum = "sha256:{digest}"\n'
            f'platforms.macos-arm64.url = {json.dumps(url)}\n'
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def mise(*arguments, capture=False):
            return subprocess.run([args.mise, *arguments], cwd=root, env=environment,
                                  check=True, text=True, capture_output=capture)
        try:
            mise("trust")
            mise("lock", "--platform", "macos-arm64")
            mise("install", "--locked")
            version = mise("exec", "--", "custom-xcode-build-service", "--version", capture=True).stdout.strip()
            if version != manifest["version"]:
                raise ValueError(f"mise installed {version!r}; expected {manifest['version']!r}.")
            payload = Path(mise("where", "github:lynnswap/swift-build", capture=True).stdout.strip())
            release.verify_payload(argparse.Namespace(
                payload=payload, disable_sandbox=False, skip_xcode_package_tests=False,
                fixture_dir=release.REPOSITORY_ROOT / "Tests/SwiftBuildTests/TestData/CommandLineTool",
            ))
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
