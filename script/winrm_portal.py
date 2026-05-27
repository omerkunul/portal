#!/usr/bin/env python3
import argparse
import getpass
import os
import shutil
import sys
import tempfile
import zipfile

from pypsrp.client import Client


def build_client(host: str, username: str, password: str) -> Client:
    return Client(
        host,
        username=username,
        password=password,
        ssl=False,
        port=5985,
        auth="ntlm",
        connection_timeout=20,
    )


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def credentials(args: argparse.Namespace) -> tuple[str, str, str]:
    host = args.host or os.environ.get("PORTAL_WIN_HOST") or "192.168.1.45"
    username = args.username or os.environ.get("PORTAL_WIN_USER")
    password = os.environ.get("PORTAL_WIN_PASS")

    if not username:
        fail("Missing Windows username. Use --username or PORTAL_WIN_USER.")
    if password is None:
        password = getpass.getpass("Windows password: ")
    return host, username, password


def print_result(output: str, streams, had_errors: bool) -> int:
    if output:
        print(output.rstrip())
    if streams.error:
        print(str(streams.error).rstrip(), file=sys.stderr)
    return 1 if had_errors else 0


def run_command(args: argparse.Namespace) -> int:
    host, username, password = credentials(args)
    client = build_client(host, username, password)
    output, streams, had_errors = client.execute_ps(args.command)
    return print_result(output, streams, had_errors)


def install_portal(args: argparse.Namespace) -> int:
    host, username, password = credentials(args)
    client = build_client(host, username, password)
    zip_path = os.path.abspath(args.zip)
    if not os.path.exists(zip_path):
        fail(f"Installer zip not found: {zip_path}")

    remote_zip = r"$env:TEMP\Portal-Windows-installer.zip"
    remote_dir = r"$env:TEMP\Portal-Windows-installer"
    client.copy(zip_path, r"%TEMP%\Portal-Windows-installer.zip")
    command = rf"""
$ErrorActionPreference = "Stop"
$zip = "{remote_zip}"
$dir = "{remote_dir}"
Unblock-File $zip -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
Expand-Archive -Force $zip $dir
Get-ChildItem $dir -Recurse | Unblock-File -ErrorAction SilentlyContinue
Set-Location $dir
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-portal.ps1 -Launch
"""
    output, streams, had_errors = client.execute_ps(command)
    return print_result(output, streams, had_errors)


def zip_windows_sources(root: str) -> str:
    temp_dir = tempfile.mkdtemp(prefix="portal-winrm-")
    archive = os.path.join(temp_dir, "PortalWindowsSource.zip")
    windows_dir = os.path.join(root, "windows")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for base, dirs, files in os.walk(windows_dir):
            dirs[:] = [item for item in dirs if item not in {"bin", "obj"}]
            for filename in files:
                path = os.path.join(base, filename)
                rel = os.path.relpath(path, root)
                zf.write(path, rel)
    return archive


def build_install_portal(args: argparse.Namespace) -> int:
    host, username, password = credentials(args)
    client = build_client(host, username, password)
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    archive = zip_windows_sources(root)
    try:
        client.copy(archive, r"%TEMP%\PortalWindowsSource.zip")
    finally:
        shutil.rmtree(os.path.dirname(archive), ignore_errors=True)

    remote_root = args.remote_dir
    command = rf"""
$ErrorActionPreference = "Stop"
$zip = "$env:TEMP\PortalWindowsSource.zip"
$root = "{remote_root}"
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
Expand-Archive -Force $zip $root
Set-Location $root
.\windows\build-windows-exe.ps1
New-Item -ItemType Directory -Force "$root\dist\Portal-Windows-installer" | Out-Null
Copy-Item -Force "$root\dist\windows\PortalWindows.exe" "$root\dist\Portal-Windows-installer\PortalWindows.exe"
Copy-Item -Force "$root\windows\install-portal.ps1" "$root\dist\Portal-Windows-installer\install-portal.ps1"
Copy-Item -Force "$root\windows\uninstall-portal.ps1" "$root\dist\Portal-Windows-installer\uninstall-portal.ps1"
Set-Location "$root\dist\Portal-Windows-installer"
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-portal.ps1 -Launch
"""
    output, streams, had_errors = client.execute_ps(command)
    return print_result(output, streams, had_errors)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Portal WinRM helper commands.")
    parser.add_argument("--host", help="Windows host IP. Defaults to PORTAL_WIN_HOST or 192.168.1.45.")
    parser.add_argument("--username", help="Windows username. Defaults to PORTAL_WIN_USER.")
    subparsers = parser.add_subparsers(dest="action", required=True)

    run_parser = subparsers.add_parser("run", help="Run a PowerShell command over WinRM.")
    run_parser.add_argument("command")
    run_parser.set_defaults(func=run_command)

    install_parser = subparsers.add_parser("install", help="Copy and install the Portal Windows package.")
    install_parser.add_argument("--zip", default="dist/Portal-Windows-installer.zip")
    install_parser.set_defaults(func=install_portal)

    build_install_parser = subparsers.add_parser("build-install", help="Copy source, build on Windows, install, and launch.")
    build_install_parser.add_argument("--remote-dir", default=r"$env:USERPROFILE\PortalBuild")
    build_install_parser.set_defaults(func=build_install_portal)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
