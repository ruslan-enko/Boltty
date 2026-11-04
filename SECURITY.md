# Security

## Reporting a problem

Please don't open a public issue. Report it privately through GitHub:
[Report a vulnerability](https://github.com/ruslan-enko/boltty/security/advisories/new).
Say what you found, how to reproduce it, and which version you have (Settings ›
General › Version). Only the latest release is supported.

## What counts

Boltty drives agent CLIs you installed yourself. An agent started from it can do
what the same CLI can do from your terminal: read your files, reach the network,
use your SSH key. Boltty isn't a sandbox, so "the agent can reach X" is not a
vulnerability in Boltty.

These are:

- Boltty giving an agent more than its CLI already had, like answering a
  permission you didn't answer or turning on a mode you didn't choose.
- Something Boltty makes itself (a server password, a transcript, a screenshot)
  reaching somewhere it shouldn't. That includes a question about part of the
  screen sending windows it shouldn't show.
- Updates: Boltty installs only this repository's release, only after you say so,
  and only if its checksum and signature match. A way around that is a finding.
