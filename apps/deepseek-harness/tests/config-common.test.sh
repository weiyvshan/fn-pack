#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${ROOT}/cmd/config-common"

validate_api_key ""
validate_api_key "sk-abcdefgh"
if validate_api_key "bad-key"; then
  echo "invalid API key was accepted" >&2
  exit 1
fi

validate_proxy_host "192.168.1.2"
validate_proxy_host "proxy.example.test"
if validate_proxy_host "bad host" || validate_proxy_host "proxy..example"; then
  echo "invalid proxy host was accepted" >&2
  exit 1
fi
validate_proxy_port "1"
validate_proxy_port "65535"
if validate_proxy_port "0" || validate_proxy_port "65536"; then
  echo "invalid proxy port was accepted" >&2
  exit 1
fi

temporary_root=$(mktemp -d)
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT INT TERM

package_home="${temporary_root}/volume/@apphome/deepseek-harness"
package_var="${temporary_root}/volume/@appdata/deepseek-harness"
mkdir -p "$package_home" "$package_var"

write_api_key "$temporary_root" "sk-abcdefgh"
[ "$(cat "${temporary_root}/.env")" = "DEEPSEEK_API_KEY=sk-abcdefgh" ]
write_proxy "$temporary_root" "proxy.example.test" "7890"
[ "$(cat "${temporary_root}/proxy.url")" = "http://proxy.example.test:7890" ]

marker_status=0
wizard_config_marker_status "$temporary_root" || marker_status=$?
[ "$marker_status" -eq 1 ]
mark_wizard_config_initialized "$temporary_root"
wizard_config_marker_status "$temporary_root"
[ "$(cat "${temporary_root}/.fnos-wizard-config-initialized")" = "initialized-v1" ]
printf '%s\n' 'invalid' >"${temporary_root}/.fnos-wizard-config-initialized"
marker_status=0
wizard_config_marker_status "$temporary_root" || marker_status=$?
[ "$marker_status" -eq 2 ]
rm -f -- "${temporary_root}/.fnos-wizard-config-initialized"

ensure_dsh_home "$package_home"
[ -d "${package_home}/.dsh/profiles/web" ]
[ -d "${package_home}/.dsh/logs" ]
ensure_dsh_home "$package_home"

runtime_root="${temporary_root}/volume/@appcenter/deepseek-harness/server"
profile_modules="${package_home}/.dsh/profiles/node_modules"
mkdir -p "${runtime_root}/node_modules/kept-runtime-package" "$profile_modules"
ln -s "${runtime_root}/node_modules/kept-runtime-package" "${profile_modules}/kept-runtime-package"
ln -s "${runtime_root}/node_modules/removed-runtime-package" "${profile_modules}/removed-runtime-package"
ensure_dsh_home "$package_home" "$runtime_root"
[ -L "${profile_modules}/kept-runtime-package" ]
[ ! -e "${profile_modules}/removed-runtime-package" ]
[ ! -L "${profile_modules}/removed-runtime-package" ]

ln -s "${temporary_root}/outside/missing-package" "${profile_modules}/outside-runtime-package"
if ensure_dsh_home "$package_home" "$runtime_root"; then
  echo 'a dangling node_modules link outside the application runtime was accepted' >&2
  exit 1
fi
rm -f -- "${profile_modules}/outside-runtime-package"

ensure_shell_state "$package_var"
[ -d "${package_var}/shell/state" ]
[ -d "${package_var}/shell/cache" ]
[ -d "${package_var}/shell/data" ]
[ "$(stat -c '%a' "${package_var}/shell")" = 700 ]

invalid_home="${temporary_root}/invalid-volume/@apphome/deepseek-harness"
invalid_var="${temporary_root}/invalid-volume/@appdata/deepseek-harness"
mkdir -p "$invalid_home" "$invalid_var"
printf '%s\n' 'not-a-directory' >"${invalid_home}/.dsh"
if ensure_dsh_home "$invalid_home"; then
  echo 'invalid .dsh object was accepted' >&2
  exit 1
fi

fake_app="${temporary_root}/fake-app"
fake_var="${temporary_root}/fake-runtime"
mkdir -p "${fake_app}/pnpm/bin" "${fake_app}/server/node_modules/@deepseek-ai/dsh/lib"
cp -- "${ROOT}/app/pnpm-launcher" "${fake_app}/pnpm-launcher"
cp -- "${ROOT}/app/dsh-launcher" "${fake_app}/dsh-launcher"
: >"${fake_app}/pnpm/bin/pnpm.cjs"
: >"${fake_app}/server/node_modules/@deepseek-ai/dsh/lib/bin.js"
install_pnpm_launcher "$fake_app" "$fake_var"
[ -x "${fake_var}/bin/pnpm" ]
install_dsh_launcher "$fake_app" "$fake_var"
[ -x "${fake_var}/bin/dsh" ]

fake_landlock="${fake_app}/server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run"
mkdir -p "$(dirname "$fake_landlock")"
printf '#!/bin/sh\nexit 0\n' >"$fake_landlock"
chmod 0600 "$fake_landlock"
prepare_landlock_launcher "$fake_app"
[ -x "$fake_landlock" ]

generated_home="${temporary_root}/generated"
mkdir -p "${generated_home}/profiles/web"
cat >"${generated_home}/profiles/web/cordis.patch.yml" <<'EOF'
- id: webserver
  config:
    host: "127.0.0.1"
    port: 44123
EOF
remove_generated_loopback_profile "$generated_home"
[ ! -e "${generated_home}/profiles/web/cordis.patch.yml" ]

custom_home="${temporary_root}/custom"
mkdir -p "${custom_home}/profiles/web"
cat >"${custom_home}/profiles/web/cordis.patch.yml" <<'EOF'
- id: webserver
  config:
    host: "127.0.0.1"
    port: 35689
  disabled: true
EOF
if remove_generated_loopback_profile "$custom_home"; then
  echo "customized web profile was removed" >&2
  exit 1
fi
[ -f "${custom_home}/profiles/web/cordis.patch.yml" ]

fake_proc="${temporary_root}/proc"
mkdir -p "${fake_proc}/101" "${fake_proc}/102"
printf 'Name:\tnode\nUid:\t4321\t4321\t4321\t4321\n' >"${fake_proc}/101/status"
printf '/node\000/fake/@appcenter/deepseek-harness/server/node_modules/@deepseek-ai/dsh/lib/bin.js\000web\000--port\0003080\000' >"${fake_proc}/101/cmdline"
printf 'Name:\tnode\nUid:\t9999\t9999\t9999\t9999\n' >"${fake_proc}/102/status"
cp -- "${fake_proc}/101/cmdline" "${fake_proc}/102/cmdline"
marker='/fake/@appcenter/deepseek-harness/server/node_modules/@deepseek-ai/dsh/lib/bin.js web'
process_identity_matches 101 4321 "$marker" "$fake_proc"
if process_identity_matches 101 9999 "$marker" "$fake_proc" ||
   process_identity_matches 102 4321 "$marker" "$fake_proc" ||
   process_identity_matches 101 4321 '/other/app/dsh/lib/bin.js web' "$fake_proc"; then
  echo "process identity validation accepted an invalid process" >&2
  exit 1
fi

echo "config-common tests passed"
