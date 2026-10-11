#!/usr/bin/env python3
"""Check publishable Git history and IPA contents without echoing sensitive values."""
import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath


PATTERNS = (
    ("personal filesystem path", rb"(?i)/(?:Users|home)/[a-z0-9][a-z0-9._-]*/"),
    ("personal Windows path", rb"(?i)[a-z]:\\Users\\[a-z0-9][a-z0-9._-]*\\"),
    ("local computer name", rb"(?i)(?<![a-z0-9._-])[a-z0-9][a-z0-9._-]+\.local(?![a-z0-9._-])"),
    ("private key material", rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    ("GitHub credential", rb"\b(?:gh[pousr]_[a-zA-Z0-9_]{20,}|github_pat_[a-zA-Z0-9_]{30,})\b"),
    ("AWS access key", rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
)
PRIVATE_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".der", ".cer", ".crt",
                    ".mobileprovision", ".profraw", ".sqlite", ".sqlite3", ".db",
                    ".xcuserstate", ".log"}
PRIVATE_PARTS = {"xcuserdata", "DerivedData", ".build", ".swiftpm", ".git", "__pycache__"}


def content_findings(data):
    return [label for label, pattern in PATTERNS if re.search(pattern, data)]


def private_path(name, archive=False):
    path = PurePosixPath(name)
    return (any(part in PRIVATE_PARTS or part.endswith(".dSYM") for part in path.parts)
            or path.suffix.lower() in PRIVATE_SUFFIXES
            or path.name == ".env" or path.name.startswith(".env.")
            or (not archive and path.suffix.lower() in {".ipa", ".zip"})
            or name == "WLOC/MainApp/Configuration/Config.plist")


def commit_identity_findings(data):
    findings = []
    for role in (b"author", b"committer"):
        match = re.search(rb"^" + role + rb" .+ <([^>]+)>", data, re.MULTILINE)
        email = match[1] if match else b""
        if not (email.endswith(b"@users.noreply.github.com") or email == b"noreply@github.com"):
            findings.append(role.decode() + " email is not a GitHub noreply address")
    return findings


def git(repo, *arguments):
    return subprocess.check_output(["git", "-C", str(repo), *arguments])


def audit_repository(repo, ref):
    findings = []
    scanned_blobs = set()
    commits = git(repo, "rev-list", ref).decode().splitlines()
    for commit in commits:
        metadata = git(repo, "cat-file", "commit", commit)
        for reason in content_findings(metadata) + commit_identity_findings(metadata):
            findings.append(f"commit {commit[:12]}: {reason}")
        records = git(repo, "ls-tree", "-rz", "--full-tree", commit).split(b"\0")
        for record in filter(None, records):
            fields, raw_name = record.split(b"\t", 1)
            mode, kind, object_id = fields.split()
            name = raw_name.decode("utf-8", "replace")
            if private_path(name):
                findings.append(f"commit {commit[:12]}: excluded personal/generated file")
            if kind != b"blob" or object_id in scanned_blobs:
                continue
            scanned_blobs.add(object_id)
            data = git(repo, "cat-file", "blob", object_id.decode())
            for reason in content_findings(data):
                findings.append(f"blob {object_id[:12].decode()}: {reason}")
    return findings


def audit_ipa(path):
    findings = []
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            findings.append("IPA has a corrupt member")
        for member in archive.infolist():
            if member.is_dir():
                continue
            if private_path(member.filename, archive=True):
                findings.append("IPA contains an excluded personal/generated file")
            for reason in content_findings(archive.read(member)):
                findings.append("IPA member: " + reason)
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--ref", default="main")
    parser.add_argument("--ipa", type=Path)
    arguments = parser.parse_args()
    if not arguments.repository and not arguments.ipa:
        parser.error("provide --repository and/or --ipa")
    findings = []
    if arguments.repository:
        findings += audit_repository(arguments.repository, arguments.ref)
    if arguments.ipa:
        findings += audit_ipa(arguments.ipa)
    if findings:
        print("Publication blocked by privacy checks:", file=sys.stderr)
        for finding in sorted(set(findings)):
            print("- " + finding, file=sys.stderr)
        return 1
    print("Publication privacy checks passed for the selected Git history/IPA")
    return 0


if __name__ == "__main__":
    sys.exit(main())
