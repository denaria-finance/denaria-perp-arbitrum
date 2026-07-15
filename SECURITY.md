# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities **privately** — do not open a public issue for a
suspected vulnerability.

- Preferred: open a private security advisory through the repository's
  **Security → Report a vulnerability** (GitHub private vulnerability reporting).

Please include:

- a description of the issue and its impact;
- the affected component (Rust/WASM `perp-engine`, the Solidity periphery, or the deploy tooling)
  and version/commit;
- reproduction steps or a proof of concept, where possible.

We aim to acknowledge reports promptly and will keep you informed of remediation progress.
Please allow a reasonable period for a fix before any public disclosure.

## Scope

This repository contains a hybrid Arbitrum Stylus system:

- the Rust/WASM `perp-engine` (the on-chain deployed engine);
- the Solidity periphery (manager, Vault, LostAndFound, oracle middleware);
- a Solidity reference engine used **only** for differential/golden-vector testing (not deployed);
- deploy, verification, and operations tooling under `script/`.

Findings in the deployed engine and periphery, and in the deploy/verification tooling, are in
scope. The Solidity reference engine under `test/` and `src/PerpPair.sol` is a non-deployed test
oracle.

## Supported Versions

Security fixes target the `main` branch and the current deployed release. There is no support
commitment for older tags or experimental branches.
