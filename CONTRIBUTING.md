# Contributing to ULPM

Thanks for helping improve ULPM. This project is a rootless, daemonless package manager written in Bash. Contributions of all sizes are welcome: bug reports, documentation, tests, modules and packaging recipes.

## Code of conduct

Be respectful, assume good faith, stay technical. Harassment or hostile behavior is not tolerated.

## Ways to contribute

- Report bugs with a minimal reproduction
- Improve documentation in `docs/`
- Add or extend tests in `tests/run.sh`
- Package applications and publish example repositories
- Support another distribution or architecture
- Review pull requests

## Before opening an issue

1. Run `ulpm doctor` and include the output.
2. Search existing issues.
3. Reproduce with the latest `main`.
4. Include: distribution, kernel, architecture, ULPM version (`ulpm --version`), exact command, expected behavior and actual behavior.

Do not include private keys, tokens, or personal paths you are not comfortable publishing.

## Security issues

Do not open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md).

## Development setup

Prerequisites:

```bash
# Debian/Ubuntu
sudo apt install bash git shellcheck jq openssl curl util-linux bubblewrap \
  squashfs-tools squashfuse file binutils python3 xdg-dbus-proxy
```

Run from a checkout, no build step:

```bash
git clone https://github.com/Ruraam/ulpm.git
cd ulpm
./bin/ulpm --help
./bin/ulpm doctor
```

## Tests and lint

```bash
bash tests/run.sh
shellcheck -x bin/ulpm bin/ulrm lib/*.sh install.sh tests/*.sh
```

The test suite must pass and ShellCheck must be clean before review. CI runs both on every push and pull request.

See [docs/development.md](docs/development.md) for architecture, conventions, test helpers and the release checklist.

## Pull request guidelines

- Keep changes focused; one logical change per pull request.
- Add tests for behavior changes.
- Update documentation when commands, flags, formats or environment variables change.
- Never break the `set -Eeuo pipefail` assumptions or weaken fail-closed behavior.
- Preserve the package format contract; schema changes require an `ULPM_FORMAT_VERSION` decision.
- Do not include generated artifacts, local paths or secrets.

### Commit messages

- Use the imperative mood: `add repository verification test`.
- Reference issues when applicable: `fix transaction rollback (#42)`.
- Keep the summary under ~72 characters.

### Pull request checklist

- [ ] `bash -n` passes for changed shell files
- [ ] `shellcheck -x` is clean
- [ ] `bash tests/run.sh` passes
- [ ] Documentation updated when needed
- [ ] No secrets, keys or local artifacts committed

## Adding commands, fields or modules

- Commands are `cmd_<name>` functions dispatched from `bin/ulpm`.
- Update `show_help`, the completion list and `docs/cli-reference.md`.
- Manifest fields must be validated in `lib/pack.sh` and documented in `docs/lpk-format.md`.
- Security-sensitive paths must keep the existing validation and symlink protections.

## Documentation

Documentation lives in `docs/`. Start at [docs/README.md](docs/README.md). Use GitHub-flavored Markdown, keep commands copy-pasteable and prefer concrete examples.

## License

By contributing, you agree that your contributions are licensed under the [GPLv3 License](LICENSE).
