# Security

## Reporting a vulnerability

Please do **not** open a public issue. Report it privately through GitHub:
**Security › Report a vulnerability** on
[ruslan-enko/boltty](https://github.com/ruslan-enko/boltty/security/advisories/new).
Say what you found, how to reproduce it, and which version
(Settings › General › Version).

Only the latest release is supported.

## What counts

Boltty drives agent CLIs you installed yourself, and an agent started through
it can do what the same CLI can do from your own terminal — read your files,
reach the network, use your SSH key. Boltty is not a sandbox, and "the agent
can reach X" is not a vulnerability in Boltty.

What is: Boltty **widening** what a CLI could already do — answering a
permission the person did not answer, turning on a mode they did not choose —
or something Boltty itself generates (a server password, a transcript, an
attachment) reaching somewhere it should not. And the update check: it
asks GitHub for the latest release and only ever says what it found — a
check that could be made to open, download or run anything is a finding.
