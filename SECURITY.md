# Security Policy

## Supported versions

Double Finder is developed on `main`. Only the newest build is supported:

| Version | Supported |
|---|---|
| Newest tagged release / the rolling `latest` prerelease | ✅ |
| Anything older | ❌ — please update first |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting instead:
**Security ▸ Advisories ▸ [Report a vulnerability](../../security/advisories/new)**.
If that is unavailable to you, email <qianwch@gmail.com> with `[double-finder
security]` in the subject.

Please include:

- what an attacker gains, and what they need to start (a malicious archive? a
  hostile SFTP/S3 server? local access to the machine?);
- the macOS version, the Mac's architecture, and the build (release tag or
  commit) you tested;
- a minimal reproduction — a sample archive, a server configuration, or a
  short screen recording.

You can expect an acknowledgement within about a week. This is a spare-time
project maintained by one person, so please treat that as a best effort rather
than a guarantee. Fixes land on `main` and go out with the next release; if you
would like credit in the release notes, say so in your report.

## Scope

Double Finder is a local desktop application with no backend service of its
own. In scope is anything in this repository, in particular the places where
it parses untrusted input or handles credentials:

- archive handling (`FileSystem/LibArchive.swift`, `ZipFS`) and the bundled
  `7zz` child process;
- the remote backends — SFTP, S3/SigV4, SMB and Android/MTP — and the way
  credentials reach them;
- the built-in Lister viewer, which renders untrusted file content, including
  Markdown, HTML and mermaid/PlantUML diagrams in a web view;
- file operations that follow symlinks or write outside the intended target.

Out of scope:

- vulnerabilities in third-party components themselves (libarchive, 7-Zip,
  libmtp, mermaid, PlantUML) — report those upstream; tell us if Double Finder
  ships an outdated copy or uses one unsafely;
- anything requiring the attacker to already have code execution as the user;
- the known design limitations listed below.

## Known limitations, by design

These are documented trade-offs, not bugs. A report that only restates one of
them will be closed as known — a report that turns one into a concrete exploit
is welcome.

- **Builds are ad-hoc signed and not notarized by Apple**, and are not
  sandboxed. Gatekeeper will warn on first launch. Only download DMGs from
  this repository's Releases page.
- **SFTP host keys are not verified.** The `ssh`/`sftp` child processes run
  with `StrictHostKeyChecking=no`, so a machine-in-the-middle on the network
  path can impersonate a server. Authentication is key-based (`BatchMode=yes`)
  — no password is ever passed to a child process — but do not treat an SFTP
  session as authenticated against a hostile network.
- **Secrets live in the macOS Keychain**, not in the preferences file; the
  preferences (`~/Library/Preferences/net.qian.double-finder.plist`) keep only
  non-secret connection metadata such as endpoints and access-key identifiers.
- **Editing a remote file (F4) downloads a plaintext temp copy** to the local
  temp directory for the duration of the edit.
