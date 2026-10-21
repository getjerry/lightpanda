# Botly compatibility fork

This fork starts from upstream `1.0.0`. Browser fixes and their regression tests
live here; Botly consumes a fixed binary from this repository's GitHub Releases.

The `fork build and release` workflow reuses upstream's dependency installation,
static V8, snapshot, and ReleaseFast build. It currently builds Linux amd64, the
architecture used by Botly's consumer image. It does not publish to upstream's
AWS, package repositories, or other projects, and needs only `GITHUB_TOKEN`.

## Validate before publishing

Push a `codex/**` branch or manually dispatch the workflow. It checks formatting,
runs all Zig tests in debug mode (including leak detection), builds the binary,
and checks the executable and MCP/CDP CLI entrypoints inside `node:22-bookworm`.
Download the `lightpanda-x86_64-linux` Actions artifact for further protocol and
workflow testing. Container CLI checks alone do not prove workflow compatibility.

## Publish a fixed version

After validating the branch artifact, push a new tag such as `1.0.0-jerry.1`.
The workflow repeats the checks and creates an experimental GitHub Release with:

- `lightpanda-x86_64-linux`
- `SHA256SUMS`
- `provenance.json`

The binary reports `<tag>+git.<12-character-source-SHA>`; branch builds report
`1.0.0-jerry.dev+git.<SHA>`. Read the exact version and size from provenance.
An existing release is never overwritten. Use a new tag for every new binary.

Botly's downloader should pin the release's asset URL, exact binary version,
size, and SHA256. Do not use `latest` or a moving branch URL. Keep the previous
Botly image digest available for rollback.
