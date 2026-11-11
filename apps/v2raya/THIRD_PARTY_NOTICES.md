# Third-party notices

## v2rayA 2.5.13 (service, embedded Web UI and official icons)

- Source: https://github.com/v2rayA/v2rayA/tree/v2.5.13
- Commit: 3c32891eb390e63e91c35d746a11de88855dae99
- License: AGPL-3.0-only, verbatim source LICENSE in app/licenses/v2rayA-AGPL-3.0.txt.
- Source archive: https://codeload.github.com/v2rayA/v2rayA/tar.gz/refs/tags/v2.5.13
  (1,860,283 bytes; SHA-256 20f03a9143231e2f04b74cdcb7125c6a44b450a4a28fac92b3e64c13916ec4d9).
- Distributed as upstream binaries without local source patches. Package lifecycle
  integration is maintained separately in this repository. Provide the above
  corresponding-source link alongside any distributed FPK; retain access to
  corresponding source and notices required by the licenses.

## v2raya_core 2.5.13

The matching core is the core/ subtree of the same source release, derived from
Xray-core. Preserve its original core/LICENSE notice (app/licenses/v2raya-core-NOTICE.txt).
MPL-2.0 text is included as app/licenses/MPL-2.0.txt, sourced from
https://raw.githubusercontent.com/spdx/license-list-data/main/text/MPL-2.0.txt
(SHA-256 66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172).
Bundled code retains its original licenses; the core notice is not a blanket
relicensing of every dependency.

## Release data and artwork

The complete selected runtime closure is extracted from the SHA-256-pinned
Debian x64 package in upstream.lock.json: paired service/core, geoip.dat,
geosite.dat and official 64/256-pixel icons. No Debian scripts are executed.
Geo data redistribution must retain the upstream datasets' attribution and
terms; inventory and source evidence will be finalized before release.
Icon provenance is recorded in assets/PROVENANCE.md.

The FPK has not been published. Dependency notice review and target NAS
acceptance are release gates, not implied by a successful local build.
