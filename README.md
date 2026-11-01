# Struct8 debug agent

The program that the Struct8 Debug Access component installs on Google Compute Engine VMs. It
lets the Struct8 agent run a network probe, a read-only diagnostic command or a shell command
on a VM that has no SSH access and no external IP address, at the level that the VM's owner
grants.

## How it reaches a VM

Struct8 reads `gce/struct8-debug.sh` from a release tag of this repository when it deploys the
VM's Terraform state, and writes it to the VM's metadata. The VM never downloads it from GitHub,
so a VM without internet access receives it, and no GitHub credential is stored on the VM. A new
version reaches a VM only through a plan and an apply of that state.

The startup script installs the program as a systemd service. When an apply changes the program
in the `struct8-debug-program` metadata key, the running program replaces itself without a
reboot.

## The channel

| Direction | Pub/Sub resource | Contents |
|---|---|---|
| Command | Topic `struct8-debug-cmd-<id>`, one subscription per VM, filtered on the `instance` attribute | Attributes `instance`, `request`, `mode`; `target` and `port` for a probe; `command` and `args` for a diagnostic command. A shell command is the message data |
| Output | Topic `struct8-debug-out-<id>` | The output as the message data. Attributes `request`, `instance`, `exit`, `truncated` and `version` |

The program acknowledges a command only after it publishes the output, and it does not run a
command that Pub/Sub delivers twice.

## Access levels

The level is the `struct8-debug-level` metadata key of the VM. The program reads it before each
command. The account that publishes commands cannot change VM metadata, so it cannot raise the
level.

| Level | What runs | Exit code when refused |
|---|---|---|
| `probes` | DNS resolution, ICMP and a TCP connection to a host and port | 2 for an invalid target |
| `diagnostics` | `ping`, `dig`, `nslookup`, `traceroute`, `ss`, `netstat`, `ip`, `route` and `hostname`, without operands that change the machine | 2 |
| `shell` | Any shell command, as root, for up to 300 seconds | — |

A command above the granted level returns exit code 3. When the level key is removed, the
program disables its service and deletes its files.

## Requirements

- Linux with a POSIX `sh`, coreutils, `sed` and `curl`: Debian, Ubuntu, RHEL, Rocky Linux, SUSE
  and Container-Optimized OS.
- A service account on the VM with the `cloud-platform` or `pubsub` scope.
- A route to the Google APIs: an external IP address, Cloud NAT or Private Google Access on the
  subnet.

## Using your own version

Fork this repository, connect a GitHub component that points to your fork to the Debug Access
component in Struct8, and set **Program file** to `gce/struct8-debug.sh`.

Important: a modified program enforces the access levels by its own rules. The levels described
above apply to the program published here.

## Versions

Each release is a tag `vX.Y.Z` that matches `VERSION` in the program. Every output carries the
version that produced it in the `version` attribute.

## Tests

`sh gce/test/run.sh` runs the program in `dash` against a stand-in for the metadata server and
the Pub/Sub API. It needs `dash`.

## License

Apache License 2.0. See [LICENSE](LICENSE).
