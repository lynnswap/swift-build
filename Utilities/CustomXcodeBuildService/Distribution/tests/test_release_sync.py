import copy
from datetime import datetime, timezone
import hashlib
import io
import json
import unittest
from unittest.mock import patch
import zipfile

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import publish_release as release
import release_sync as sync
from test_tap_delivery import FakeTap, render_formula


def archive(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as output:
        for name, content in files.items():
            output.writestr(name, content)
    return data.getvalue()


class FakeCore:
    repository = "example/core"

    def __init__(self):
        sha = "a" * 40
        self.draft = dict(id=42, tag_name="v1.2.3", target_commitish=sha, name="v1.2.3",
                          body="Approved notes", draft=True, prerelease=False)
        self.run = dict(id=99, workflow_id=11, head_branch="main", head_sha=sha, event="workflow_dispatch",
                        created_at="2026-10-01T00:00:00Z", status="completed", run_attempt=1,
                        display_title=f"Release draft 42 at {sha}")
        names = (sync.APPROVAL_JOB, "Check approved draft", "Package approved source and Formula",
                 "Test approved source / Required distribution checks", sync.RECEIPT_JOB, sync.PROBE_JOB)
        self.jobs = [dict(name=name, id=100 + n, run_attempt=1, status="completed", conclusion="success")
                     for n, name in enumerate(names)]
        self.calls = []
        digest = hashlib.sha256(b"prepared source").hexdigest()
        self.formula = render_formula("v1.2.3", self.repository, digest)
        sums = (f"{digest}  custom-xcode-build-service-1.2.3.tar.gz\n"
                f"{hashlib.sha256(self.formula.encode()).hexdigest()}  custom-xcode-build-service.rb\n")
        self.receipt = dict(release_id=42, version="v1.2.3", target=sha,
                            content_digest=release.fingerprint(self.draft), source_artifact_id=2,
                            checksums_sha256=hashlib.sha256(sums.encode()).hexdigest())
        self.source_files = {"custom-xcode-build-service-1.2.3.tar.gz": b"prepared source",
                             "custom-xcode-build-service.rb": self.formula, "SHA256SUMS.txt": sums}
        self.refresh_archives()

    def refresh_archives(self):
        self.bytes = {1: archive({"release-plan.json": json.dumps(self.receipt)}), 2: archive(self.source_files)}
        self.artifacts = [dict(id=key, name="release-plan-1" if key == 1 else "release-assets-1",
                               expired=False, created_at="2026-10-01T00:01:00Z",
                               digest="sha256:" + hashlib.sha256(value).hexdigest())
                          for key, value in self.bytes.items()]

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method))
        if path == "": return dict(default_branch="main")
        if path == "actions/workflows/custom-xcode-build-service-release.yml": return dict(id=11)
        if path.startswith("releases?"): return [copy.deepcopy(self.draft)]
        if path.startswith("actions/workflows/11/runs?"): return dict(workflow_runs=[copy.deepcopy(self.run)])
        if path.startswith("actions/runs/99/jobs?"): return dict(jobs=copy.deepcopy(self.jobs))
        if path.startswith("actions/runs/99/artifacts?"): return dict(artifacts=copy.deepcopy(self.artifacts))
        if path == "releases/42": return copy.deepcopy(self.draft)
        if path == "git/ref/tags/v1.2.3": return dict(object=dict(type="commit", sha="a" * 40))
        if path == "actions/runs/99": return copy.deepcopy(self.run)
        if path == "actions/jobs/105/rerun" and method == "POST":
            self.run["status"] = "in_progress"
            return {}
        raise AssertionError((path, method))


class ReleaseResumptionTests(unittest.TestCase):
    def setUp(self):
        clock = patch.object(sync, "datetime", wraps=datetime)
        mocked = clock.start()
        mocked.now.return_value = datetime(2026, 10, 4, tzinfo=timezone.utc)
        self.addCleanup(clock.stop)
        self.core = FakeCore()
        block = ('\n  bottle do\n'
                 '    root_url "https://github.com/lynnswap/homebrew-tap/releases/download/custom-xcode-build-service-1.2.3"\n'
                 f'    sha256 cellar: :any_skip_relocation, arm64_tahoe: "{"b" * 64}"\n  end\n')
        self.tap = FakeTap(self.core.formula.replace('  license "Apache-2.0"', '  license "Apache-2.0"' + block))
        self.bytes_patch = patch.object(sync, "artifact_bytes", side_effect=lambda gh, artifact_id: self.core.bytes[artifact_id])
        self.tap_patch = patch.object(release, "GitHub", return_value=self.tap)
        self.bytes_patch.start()
        self.tap_patch.start()
        self.addCleanup(self.bytes_patch.stop)
        self.addCleanup(self.tap_patch.stop)

    def result(self, dry_run=False):
        return sync.synchronize(self.core, dry_run)[0]

    def assert_no_writes(self):
        self.assertTrue(all(method == "GET" for _, method in self.core.calls))

    def test_ready_receipt_resumes_only_the_original_probe_and_dependents(self):
        value = self.result()
        self.assertEqual(value["status"], "resumed")
        self.assertEqual(value["job_id"], 105)
        self.assertEqual([call for call in self.core.calls if call[1] == "POST"], [("actions/jobs/105/rerun", "POST")])
        self.assertEqual(self.result()["status"], "running")

    def test_waiting_tap_and_dry_run_never_mutate(self):
        self.tap.formula = self.tap.formula.replace("v1.2.3.tar.gz", "v1.2.2.tar.gz")
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()
        self.tap.formula = self.tap.formula.replace("v1.2.2.tar.gz", "v1.2.3.tar.gz")
        self.assertEqual(self.result(dry_run=True)["status"], "ready")
        self.assert_no_writes()

    def test_changed_notes_and_wrong_receipt_release_require_attention(self):
        self.core.draft["body"] = "Unapproved change"
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()
        self.core.draft["body"] = "Approved notes"
        self.core.receipt["release_id"] = 43
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_unapproved_preparation_and_real_installation_failure_are_not_retried(self):
        for name in (sync.APPROVAL_JOB, "Test approved source / Required distribution checks"):
            original = copy.deepcopy(self.core.jobs)
            next(job for job in self.core.jobs if job["name"] == name)["conclusion"] = "failure"
            self.assertEqual(self.result()["status"], "blocked")
            self.core.jobs = original
        self.core.jobs.append(dict(name="Verify published tap installation", id=106, run_attempt=1,
                                   status="completed", conclusion="failure"))
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_artifact_digest_expiry_and_source_checksum_failures_block_resumption(self):
        self.core.artifacts[0]["digest"] = "sha256:" + "0" * 64
        self.assertEqual(self.result()["status"], "blocked")
        self.core.refresh_archives()
        self.core.artifacts[1]["expired"] = True
        self.assertEqual(self.result()["status"], "blocked")
        self.core.source_files["custom-xcode-build-service-1.2.3.tar.gz"] = b"changed source"
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_foreign_workflow_and_receipt_artifacts_do_not_authorize_actions(self):
        self.core.run["workflow_id"] = 12
        self.assertEqual(self.result()["status"], "waiting")
        self.core.run["workflow_id"] = 11
        self.core.receipt["source_artifact_id"] = 999
        self.core.refresh_archives()
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_latest_attempt_failure_is_not_hidden_by_an_older_success(self):
        job = copy.deepcopy(self.core.jobs[0])
        job.update(id=200, run_attempt=2, conclusion="failure")
        self.core.jobs.append(job)
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()

    def test_prereleases_published_releases_and_running_runs_do_not_restart(self):
        self.core.draft["prerelease"] = True
        self.assertEqual(sync.synchronize(self.core), [])
        self.core.draft.update(prerelease=False, draft=False)
        self.assertEqual(sync.synchronize(self.core), [])
        self.core.draft["draft"] = True
        self.core.run["status"] = "in_progress"
        self.assertEqual(self.result()["status"], "running")
        self.assert_no_writes()

    def test_a_new_attempt_started_during_readiness_does_not_duplicate_rerun(self):
        api = self.core.api
        def changed(path, method="GET", data=None):
            if path == "actions/runs/99":
                self.core.run["run_attempt"] += 1
            return api(path, method, data)
        self.core.api = changed
        self.assertEqual(self.result()["status"], "running")
        self.assert_no_writes()

    def test_expired_rerun_window_requires_new_preparation_even_with_live_artifacts(self):
        self.core.run["created_at"] = "2026-09-03T00:00:00Z"
        for dry_run in (False, True):
            with self.subTest(dry_run=dry_run):
                value = self.result(dry_run)
                self.assertEqual(value["status"], "blocked")
                self.assertIn("new preparation run", value["reason"])
                self.assert_no_writes()

    def test_new_preparations_require_successful_tap_key_approval(self):
        self.core.jobs.append(dict(name=sync.TAP_APPROVAL_JOB, id=110, run_attempt=1,
                                   status="completed", conclusion="skipped"))
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()
        self.core.jobs[-1]["conclusion"] = "failure"
        self.assertEqual(self.result()["status"], "blocked")
        self.assert_no_writes()
        self.core.jobs[-1]["conclusion"] = "success"
        self.assertEqual(self.result(dry_run=True)["status"], "ready")
        self.assert_no_writes()

    def prepare_publication_failure(self):
        for name, result in (("Verify published tap installation", "success"),
                             ("Review verified release outputs", "success"),
                             ("Publish verified source release", "failure")):
            self.core.jobs.append(dict(name=name, id=200+len(self.core.jobs), run_attempt=1,
                                       status="completed", conclusion=result))
        self.core.run["conclusion"] = "failure"

    def test_explicit_publication_retry_reuses_only_passed_preparation_and_tested_assets(self):
        self.prepare_publication_failure()
        evidence = release.verify_homebrew_ready(self.tap, self.core.draft["tag_name"], self.write_assets())
        with patch.object(sync, "installed_delivery", return_value=evidence), patch.object(release, "publish") as publish:
            sync.publish_prepared(self.core,42,99)
        self.assertEqual(publish.call_count,1)
        args=publish.call_args.args
        self.assertEqual(args[:4],(self.core,42,"a"*40,self.core.receipt["content_digest"]))
        self.assertEqual(args[5],evidence)
        self.assert_no_writes()

    def write_assets(self):
        import tempfile
        directory=tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root=Path(directory.name)
        for name,data in self.core.source_files.items():
            (root/name).write_bytes(data.encode() if isinstance(data,str) else data)
        return root

    def test_publication_retry_rejects_failed_installation_changed_notes_and_bottle(self):
        self.prepare_publication_failure()
        with patch.object(sync,"installed_delivery", return_value=dict(formula_sha256="0"*64,bottle_sha256="b"*64,bottle_url="changed")), patch.object(release,"publish") as publish:
            with self.assertRaisesRegex(release.ReleaseError,"changed after successful installation"):
                sync.publish_prepared(self.core,42,99)
            next(job for job in self.core.jobs if job['name']=="Verify published tap installation")['conclusion']="failure"
            with self.assertRaisesRegex(release.ReleaseError,"needs attention"):
                sync.publish_prepared(self.core,42,99)
            next(job for job in self.core.jobs if job['name']=="Verify published tap installation")['conclusion']="success"
            self.core.draft['body']='changed'
            with self.assertRaises(release.ReleaseError):
                sync.publish_prepared(self.core,42,99)
            publish.assert_not_called()
        self.assert_no_writes()

    def test_foreign_or_running_run_cannot_authorize_final_publication(self):
        self.prepare_publication_failure()
        for field,value in (("workflow_id",12),("head_branch","feature"),("status","in_progress"),("display_title","foreign")):
            old=self.core.run[field]
            self.core.run[field]=value
            with self.subTest(field=field), patch.object(release,"publish") as publish:
                with self.assertRaises(release.ReleaseError):
                    sync.publish_prepared(self.core,42,99)
                publish.assert_not_called()
            self.core.run[field]=old
        self.assert_no_writes()

    def test_installed_delivery_requires_unique_json_identity_and_preserves_transport_errors(self):
        evidence=dict(formula_sha256="a"*64,bottle_sha256="b"*64,bottle_url="https://example.test/bottle")
        with patch.object(sync.subprocess,"run") as run:
            run.return_value=type('Result',(),dict(returncode=0,stdout='2026-10-04T00:00:00Z '+json.dumps(evidence)+'\n',stderr=''))()
            self.assertEqual(sync.installed_delivery(self.core,7),evidence)
            run.return_value.stdout += run.return_value.stdout
            with self.assertRaisesRegex(release.ReleaseError,"unique"):
                sync.installed_delivery(self.core,7)
            run.return_value.returncode=1
            run.return_value.stderr='Forbidden'
            with self.assertRaisesRegex(release.ReleaseError,"Forbidden"):
                sync.installed_delivery(self.core,7)

    def test_pre_receipt_runs_are_not_adopted_automatically(self):
        self.core.jobs = [job for job in self.core.jobs if job["name"] != sync.RECEIPT_JOB]
        self.assertEqual(self.result()["status"], "waiting")
        self.assert_no_writes()


if __name__ == "__main__":
    unittest.main()
