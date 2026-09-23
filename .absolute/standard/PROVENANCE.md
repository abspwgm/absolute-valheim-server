# Vendored standard

This directory is a copy of the machine-readable half of the Absolute
engineering standard, taken at the commit this repository was already pinned
to: `fad83f7faa00efd2b29b88ca332f7358c553ee05`, standard version **1.0.0**, matching the `standard_version`
declared in `../policy.yml`.

It is vendored because the standard now lives in a private repository, and a
public repository cannot call a reusable workflow from a private one. Only what
`check.py` actually reads is here — the prose (`STANDARD.md`,
`BASELINE.md`) is not.

| Path | What it is |
|---|---|
| `VERSION` | The standard version `check.py` compares against `../policy.yml` (7.3) |
| `conformance/check.py` | The conformance check |
| `security/baseline.policy.yml` | The seven-layer security floor (clause 6) |
| `security/base-images.yml` | The approved base image library |

## Differences from the original

The secret-scanner escape hatch is spelled `absolute-conformance:allow-secret`
here, not the name the standard uses. The old spelling contained the private
repository's name, which is the thing this copy exists to avoid publishing. No
file in this repository used the marker when it was renamed.

### The signature table is renamed

The signature table `check.py` scans with is named `LEAK_SIGNATURES` here,
not the name the upstream copy used at this version. A constant whose name
reads like a credential is classified as sensitive data by code scanning, which
then reports every finding built from it as a clear-text leak -- a false alert,
since only the pattern's label ever reaches a finding and never the matched
text. Carrying the old name meant a standing high-severity false positive in
this repository, and the same alert wherever this checker is carried. The
rename is the whole change; the patterns, the labels and the behaviour are
untouched. It is upstream as well, so the next refresh absorbs it.

## Keeping it current

`check.py` compares `VERSION` against `../policy.yml` exactly, so these
move together or the check fails. Refreshing to a newer standard means copying
these four files again from that version and bumping `standard_version` in the
same pull request.
