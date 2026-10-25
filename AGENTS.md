# Maintainer notes (plugin-kernel-sh)

Marketplace `plugin-kernel-sh` with two independently versioned Claude Code plugins for [Kernel](https://kernel.sh) cloud browsers: `kernel-browser` (use a cloud browser) and `kernel-dev` (write code that uses Kernel). Claude Code only; there is no Codex packaging.

- Layout: `plugins/kernel-browser/` and `plugins/kernel-dev/` (each is the whole installed plugin), `shared/lib/` (hook library copied into both plugins by `scripts/sync-shared.sh`; edit `shared/lib/`, then run the script), `lab/` (maintainer smoke tests against the live API), `tests/` (kernel-dev hook, detection and rule tests).
- Read `DECISIONS.md` and `verified-facts.md` before changing behavior; the README quotes the ledger counts and `scripts/validate.sh` fails when they drift.
- Local checks: `scripts/validate.sh` (also the release gate, `scripts/release-gate.sh`), `sh tests/run.sh --all-shells`, `scripts/secret-scan.sh --tree` (this repo's own scan, also a pre-commit use) and `cd lab && npm install && node ../scripts/typecheck-snippets.mjs`.
- Never put a Kernel API key or a 1Password token in this repo, a test, a fixture or a command line.

<!-- kit:agents:start -->
## Releases, versions and installs (shared by every plugin repo)

- **Never bump a version by hand.** `.github/workflows/release.yml` runs after `ci` is green on `main`. `scripts/kit/release.py` reads the conventional-commit subjects since the last release tag (`feat` is a minor, `fix`/`perf`/unprefixed a patch, `type!:` or a BREAKING CHANGE line a major, a minor while the version is 0.x; docs, ci, chore, test, style, build and refactor release nothing) and counts only commits that touch shipped files. It writes every manifest, the marketplace entries and CHANGELOG.md, commits `chore(release): vX [skip ci]`, tags `vX` and `<plugin>--vX` (several plugins: `<plugin>--vX` only) and publishes the GitHub release. `python3 scripts/kit/release.py` with no flags prints what it would do; Actions > release > Run workflow forces a level or a dry run.
- **One version source: the manifests** (`.claude-plugin/plugin.json`, the marketplace entry). Never a constant in code; read the manifest at runtime.
- Installed copies update only when the version string changes, so a change users should get must reach `main` as a releasing commit type (`feat`, `fix`, `perf`, or `!`).
- **Install policy:** installed globally and off (`"defaultEnabled": false`), switched on per project with `plugin on <name>`. Never document a project-scope install as the way in.
- `scripts/kit/*`, `scripts/kit.sha256`, `.github/workflows/release.yml`, the `kit:manifests` job in `ci.yml` and the blocks between `kit:` markers in README.md and AGENTS.md are copies from [yigitkonur/plugin-kit](https://github.com/yigitkonur/plugin-kit). Change them there and run its `sync.sh`; `scripts/kit/check-manifests.py` fails CI on a local edit.
- Before pushing: `python3 scripts/kit/check-manifests.py --validate`, `python3 scripts/kit/secret-scan.py --tree`, `python3 scripts/kit/check-links.py`, then this repo's own checks.
<!-- kit:agents:end -->
