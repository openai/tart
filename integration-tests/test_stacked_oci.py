import os
import platform
import subprocess
import uuid
from typing import Optional

import pytest
from paramiko.client import AutoAddPolicy, SSHClient


def _macos_major_version() -> int:
    version = platform.mac_ver()[0]
    return int(version.split(".", maxsplit=1)[0]) if version else 0


def _shutdown_vm(tart, vm_name: str, guest_command: Optional[str] = None) -> None:
    tart_run_process = tart.run_async(["run", "--no-graphics", vm_name])
    client = None

    try:
        stdout, _ = tart.run(["ip", vm_name, "--wait", "180"])
        client = SSHClient()
        client.set_missing_host_key_policy(AutoAddPolicy)
        client.connect(stdout.strip(), username="admin", password="admin")
        if guest_command:
            _, command_stdout, command_stderr = client.exec_command(guest_command)
            assert command_stdout.channel.recv_exit_status() == 0, command_stderr.read().decode()
        client.exec_command("sudo shutdown -h now")

        tart_run_process.wait(timeout=180)
        assert tart_run_process.returncode == 0
    finally:
        if client is not None:
            client.close()
        if tart_run_process.poll() is None:
            tart_run_process.terminate()
            try:
                tart_run_process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                tart_run_process.kill()
                tart_run_process.wait(timeout=30)


@pytest.mark.skipif(
    _macos_major_version() < 27,
    reason="stacked disk images require DiskImageKit on macOS 27 or newer",
)
def test_stacked_oci_round_trip_and_boot(tart, docker_registry):
    suffix = str(uuid.uuid4())
    source_image = os.environ.get(
        "TART_STACKED_INTEGRATION_BASE_IMAGE",
        "ghcr.io/cirruslabs/macos-tahoe-base:latest",
    )
    source_clone_args = ["clone"]
    if os.environ.get("TART_STACKED_INTEGRATION_BASE_INSECURE") == "1":
        source_clone_args.append("--insecure")
    standalone_vm = f"stacked-base-{suffix}"
    stacked_vm = f"stacked-child-{suffix}"
    restored_vm = f"stacked-restored-{suffix}"
    base_remote = docker_registry.remote_name(f"stacked-base-{suffix}")
    child_remote = docker_registry.remote_name(f"stacked-child-{suffix}")

    try:
        # Publish a normal Tart image, then start a stacked lineage from that
        # remote image. The base remains a normal flat OCI image.
        tart.run(source_clone_args + [source_image, standalone_vm])
        tart.run(["push", "--insecure", standalone_vm, base_remote])
        tart.run(["clone", "--insecure", "--stacked", base_remote, stacked_vm])

        stacked_path = os.path.join(tart.home(), "vms", stacked_vm)
        assert os.path.isfile(os.path.join(stacked_path, "overlay.asif"))
        assert os.path.isfile(os.path.join(stacked_path, "manifest.json"))
        assert not os.path.exists(os.path.join(stacked_path, "disk.img"))

        # Boot once so the top ASIF overlay contains real guest writes, then
        # exercise stacked push, pull, clone, assembly, and a second boot.
        _shutdown_vm(tart, stacked_vm, "touch ~/stacked-round-trip-marker")
        tart.run(["push", "--insecure", stacked_vm, child_remote])
        tart.run(["delete", stacked_vm])
        tart.run(["pull", "--insecure", child_remote])
        tart.run(["clone", child_remote, restored_vm])

        restored_path = os.path.join(tart.home(), "vms", restored_vm)
        assert os.path.isfile(os.path.join(restored_path, "overlay.asif"))
        assert os.path.isfile(os.path.join(restored_path, "manifest.json"))
        assert not os.path.exists(os.path.join(restored_path, "disk.img"))

        _shutdown_vm(tart, restored_vm, "test -f ~/stacked-round-trip-marker")
    finally:
        for vm_name in (restored_vm, stacked_vm, standalone_vm, child_remote, base_remote):
            try:
                tart.run(["delete", vm_name])
            except Exception:
                pass
