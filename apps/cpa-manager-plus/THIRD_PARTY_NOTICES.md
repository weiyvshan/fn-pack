# Third-Party Notices

CPA Manager Plus for fnOS bundles the following locked upstream release
components:

- CPA Manager Plus 1.14.7, official Linux amd64 release, copyright Seakee,
  MIT License.
- CLIProxyAPI 8.0.32, official Linux amd64 release, copyright Luis Pater and
  Router-For.ME, MIT License.

CPA Manager Plus keeps first-class CLIProxyAPI v8 configuration support,
including client keys under `access.api-keys`, so both components are upgraded
together. The manager release declares a minimum CLIProxyAPI baseline rather
than a fixed version, and the bundled proxy release preserves the same GLIBC
requirements and the plugin-enabled build flavour as the previous one.

The credential time policy plugin is not bundled. Historical plugin sources
and UI patches are excluded from this publishing repository.

License texts are packaged under `app/licenses/`. Official release URLs,
archive hashes and extracted binary hashes are pinned in `binary.lock.json`.
Downloaded artifacts remain in the ignored `.tmp/` cache.
