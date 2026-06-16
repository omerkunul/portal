# Contributing to Portal

Thanks for contributing.

## Before you start

- Open an issue or discussion for large changes
- Keep changes scoped and reviewable
- Prefer small pull requests over broad refactors

## Development setup

### macOS app

```bash
cd mac/PortalMac
swift test
```

From the repository root, build and launch the app with:

```bash
./script/build_and_run.sh
```

### Windows app

Build on Windows:

```powershell
.\windows\build-windows-exe.ps1
```

Package the Windows installer:

```powershell
.\windows\package-windows-installer.ps1
```

## Contribution guidelines

- Follow existing code style and naming
- Prefer focused, testable changes
- Update docs when behavior changes
- Do not commit machine-specific secrets, IPs, usernames, or signing identities

## Pull request checklist

- The project builds locally
- Relevant tests pass
- Documentation is updated if needed
- No local credentials or personal environment details were introduced

## Areas where help is especially useful

- multi-display behavior
- transport hardening
- Windows packaging polish
- macOS onboarding and permissions UX
- documentation and examples
