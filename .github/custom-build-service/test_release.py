"""Distribution contract tests; no build or per-user installation is performed."""

import argparse
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import release


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.payload = self.build / "payload"
        (self.payload / "bin").mkdir(parents=True)
        service = self.payload / "libexec/swift-build"
        service.mkdir(parents=True)
        for path in (self.payload / "bin/custom-xcode-build-service", service / "SWBBuildServiceBundle"):
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        for name in release.BUNDLES:
            resources = service / name / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "spec.xcspec").write_bytes(b"resource content\x00\xff")
        for name in ("swift-build", "swift-driver"):
            directory = self.payload / "licenses" / name
            directory.mkdir(parents=True)
            (directory / "LICENSE.txt").write_text(f"License for {name}\n")
        self.manifest = dict(schemaVersion=1, version="custom-v1.2.3-beta.1", sourceRevision="a" * 40,
                             xcodeVersion="27.0", xcodeBuildVersion="27A5252f", architecture="arm64",
                             minimumMacOSVersion="26.0", resourceBundles=list(release.BUNDLES),
                             dependencies=[dict(identity="swift-driver", revision="b" * 40)])
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        template = self.build / "source/Utilities/install-custom-xcode-build-service.sh.in"
        template.parent.mkdir(parents=True)
        template.write_text('#!/bin/bash\nversion="@VERSION@"\nrepository="@REPOSITORY@"\n')

    def package(self, name="release"):
        destination = self.root / name
        release.package(argparse.Namespace(build_dir=self.build, output_dir=destination))
        return destination

    def test_round_trip_preserves_resources_binaries_licenses_and_manifest(self):
        directory = self.package()
        extracted = self.root / "unpacked elsewhere"
        extracted.mkdir()
        release.extract_archive(directory / release.ARCHIVE, extracted)
        self.assertEqual(release.validate_payload(extracted), self.manifest)
        self.assertEqual((directory / "SHA256SUMS.txt").read_text(), release.checksum_file(directory))
        for source in self.payload.rglob("*"):
            if source.is_file():
                destination = extracted / source.relative_to(self.payload)
                self.assertEqual(source.read_bytes(), destination.read_bytes())
                self.assertEqual(bool(source.stat().st_mode & 0o111), bool(destination.stat().st_mode & 0o111))
        self.assertIn('version="custom-v1.2.3-beta.1"', (directory / "install.sh").read_text())
        self.assertIn('repository="lynnswap/swift-build"', (directory / "install.sh").read_text())

    def test_repackaging_is_stable_and_refuses_existing_output(self):
        first = self.package("first")
        second = self.package("second")
        self.assertEqual((first / release.ARCHIVE).read_bytes(), (second / release.ARCHIVE).read_bytes())
        with self.assertRaisesRegex(ValueError, "must be empty"):
            self.package("first")
        self.assertEqual((first / release.ARCHIVE).read_bytes(), (second / release.ARCHIVE).read_bytes())

    def test_missing_bundle_is_rejected_before_archive_is_created(self):
        import shutil
        shutil.rmtree(self.payload / "libexec/swift-build" / release.BUNDLES[0])
        with self.assertRaisesRegex(ValueError, "resources"):
            self.package()
        self.assertFalse((self.root / "release").exists())

    def test_external_payload_symlink_is_rejected(self):
        (self.payload / "licenses/swift-driver/external").symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "Non-regular payload"):
            self.package()

    def test_archive_traversal_links_and_duplicates_are_rejected_before_extraction(self):
        cases = (("../outside", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                 ("bin/link", tarfile.SYMTYPE), ("bin/hardlink", tarfile.LNKTYPE),
                 ("bin/fifo", tarfile.FIFOTYPE), ("bin/file", tarfile.REGTYPE))
        for index, (name, kind) in enumerate(cases):
            with self.subTest(name=name):
                archive_path = self.root / f"unsafe-{index}.tar.gz"
                with tarfile.open(archive_path, "w:gz") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/etc/passwd" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
                    archive.addfile(member, io.BytesIO())
                    if name == "bin/file":
                        archive.addfile(member, io.BytesIO())
                destination = self.root / f"extracted-{index}"
                destination.mkdir()
                with self.assertRaises(ValueError):
                    release.extract_archive(archive_path, destination)
                self.assertEqual(list(destination.iterdir()), [])

    def test_tampered_asset_fails_before_platform_or_executable_checks(self):
        directory = self.package()
        with (directory / release.ARCHIVE).open("ab") as contents:
            contents.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksums"):
            release.verify(argparse.Namespace(release_dir=directory))

    def test_dependency_requires_license_and_unique_revision_entry(self):
        self.manifest["dependencies"].append(dict(identity="swift-system", revision="c" * 40))
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "License directories"):
            release.validate_payload(self.payload)
        self.manifest["dependencies"][1] = self.manifest["dependencies"][0]
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "Duplicate dependency"):
            release.validate_payload(self.payload)


if __name__ == "__main__":
    unittest.main()
