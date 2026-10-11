import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_publication_privacy import (
    audit_ipa, audit_repository, commit_identity_findings, content_findings, private_path,
)


class PublicationPrivacyTests(unittest.TestCase):
    def test_personal_paths_in_binary_contents_are_rejected(self):
        path = ("/" + "Users/" + "test-account/project/Main.swift").encode()
        self.assertIn("personal filesystem path", content_findings(b"\0" + path + b"\0"))

    def test_private_key_and_credentials_are_rejected_without_printing_values(self):
        marker = ("-----BEGIN " + "PRIVATE KEY-----").encode()
        self.assertIn("private key material", content_findings(marker))
        token = ("gh" + "p_" + "A" * 36).encode()
        self.assertEqual(content_findings(token), ["GitHub credential"])
        self.assertNotIn(token.decode(), repr(content_findings(token)))

    def test_personal_email_in_commit_metadata_is_rejected(self):
        email = b"person" + b"@" + b"example.org"
        metadata = b"author Test <" + email + b"> 1 +0000\ncommitter Test <" + email + b"> 1 +0000\n"
        self.assertEqual(len(commit_identity_findings(metadata)), 2)

    def test_noreply_commit_metadata_is_accepted(self):
        metadata = b"author Test <test@users.noreply.github.com> 1 +0000\ncommitter GitHub <noreply@github.com> 1 +0000\n"
        self.assertEqual(commit_identity_findings(metadata), [])

    def test_local_hostnames_are_rejected_without_rejecting_queue_identifiers(self):
        hostname = ("test-computer" + ".local").encode()
        self.assertEqual(content_findings(b"<" + hostname + b">"), ["local computer name"])
        self.assertEqual(content_findings(b"com.example.App.local-socks5"), [])

    def test_personal_editor_state_certificates_and_preferences_are_excluded(self):
        for path in ("Project/xcuserdata/test.xcuserdatad/state", "profile.mobileprovision",
                     "key.p12", "leaf-private-key.der", "favorites.sqlite", ".env",
                     "DerivedData/result.xcresult/Info.plist", "dist/test.ipa"):
            with self.subTest(path=path):
                self.assertTrue(private_path(path))
        self.assertFalse(private_path("WLOC/MainApp/Services/CertificateService.swift"))

    def test_ipa_scans_decompressed_members(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "sample.ipa"
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/App.app/App", "/" + "Users/" + "test-account/source.swift")
            self.assertTrue(any("personal filesystem path" in finding for finding in audit_ipa(path)))

    def test_private_key_file_is_blocked_even_without_a_pem_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "sample.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/App.app/leaf-private-key.der", b"fixture")
            self.assertTrue(audit_ipa(path))

    def test_old_history_is_scanned_even_if_head_removed_a_private_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*arguments):
                return subprocess.check_output(["git", "-C", folder, *arguments], stderr=subprocess.DEVNULL)
            git("init", "-q", "-b", "main")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@users.noreply.github.com")
            (root / "leaked.key").write_text("fixture")
            git("add", ".")
            git("commit", "-q", "-m", "Test fixture")
            git("rm", "-q", "leaked.key")
            (root / "README.md").write_text("Clean current tree")
            git("add", ".")
            git("commit", "-q", "-m", "Remove fixture")
            self.assertTrue(audit_repository(root, "main"))


if __name__ == "__main__":
    unittest.main()
