# 3.0 dependency scan review

`cargo audit` exited1 and reported15 lockfile advisories. This is not a vulnerability clearance or proof every advisory is reachable in the no-default-features native core. Triage the actual dependency/features before public release. Raw local evidence: native/dist/cargo-audit.json. OSV scanner was not installed.

| Advisory | Package | Version | Patched requirement |
| --- | --- | --- | --- |
| RUSTSEC-2026-0387 | crypto-bigint | 0.7.5 | >=0.7.6 |
| RUSTSEC-2026-0385 | ctutils | 0.4.2 | >=0.4.4 |
| RUSTSEC-2026-0258 | h2 | 0.4.15 | >=0.4.16 |
| RUSTSEC-2023-0071 | rsa | 0.9.10 | >=0.10.0 |
| RUSTSEC-2026-0346 | rustls | 0.23.43 | >=0.23.46 |
| RUSTSEC-2026-0285 | rustls | 0.23.43 | >=0.23.45 |
| RUSTSEC-2026-0348 | rustls | 0.23.43 | >=0.23.46 |
| RUSTSEC-2026-0349 | rustls | 0.23.43 | >=0.23.46 |
| RUSTSEC-2026-0382 | rustls-webpki | 0.103.13 | >=0.103.16, <0.104.0-alpha.1, >=0.104.0-alpha.8 |
| RUSTSEC-2026-0383 | webpki-root-certs | 1.0.9 | >=1.0.10 |
| RUSTSEC-2026-0381 | webpki-roots | 1.0.9 | >=1.0.10 |
| RUSTSEC-2026-0429 | zip | 8.6.0 | >=9.0.0 |
| RUSTSEC-2026-0367 | zip | 8.6.0 | >=9.0.0 |
| RUSTSEC-2026-0368 | zip | 8.6.0 | >=9.0.0 |
| RUSTSEC-2026-0369 | zip | 8.6.0 | >=9.0.0 |

No dependency upgrades were silently applied to the confirmed2.9.2 signing/authentication stack. Source/archive guards may constrain exploitability but do not close these advisories by assertion. Public release recommendation remains NO LAUNCH until triage and user acceptance; local acceptance build is installed.
