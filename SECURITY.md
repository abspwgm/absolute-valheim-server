# Security policy

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting on this
repository ("Report a vulnerability" under the Security tab). Do not open a
public issue for a vulnerability.

You should get an acknowledgement within 7 days and an assessment within 14. If
a fix is needed, we will agree a disclosure date with you before publishing.

Most valuable here: a way to get code into a server through the image — an
unverified download path, a mod that installs without matching its pin, a way to
reach the container's filesystem from the game — and anything that makes the
disaster-response path (`valheim-dr`) restore something an operator did not
choose.

## What this repository never contains

This is a public repository for a public image. It carries no detail of any real
deployment: no addresses, hostnames, network layout or firewall rules, in the
code, the documentation, commit messages, PR bodies or issues. Examples use
`192.168.1.50` and the documentation range `203.0.113.0/24`. Site-specific
configuration lives outside this repository, and nothing here points at it.

If you find deployment detail in this repository's history, report it privately
rather than opening an issue.

## Secrets

No secret belongs in this repository, in a string literal, in a build argument
or in an example file. The server password and any operator credential arrive at
run time through the environment or a file the operator supplies.

## Where findings live

Bills of material for the published images are public: they are attached to each
image as provenance and SBOM attestations. Audit findings, unpatched
vulnerabilities and licence exceptions under review are kept privately, not in
this repository's issues or workflow artifacts.

## Standard

This repository conforms to the
[Absolute engineering standard](https://github.com/abspwgm/.github);
its security baseline is layered L1 to L7, and this repository's answers,
including its open exceptions, are in [`.absolute/policy.yml`](.absolute/policy.yml).
