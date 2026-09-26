#!/usr/bin/env bash
# Install asdf and the versions from .tool-versions on GitLab.com / GitHub hosted
# runners (no Tart image, no project-builder). Safe to re-run. Source this file
# so PATH/shims survive into later CI script steps.
#
# Do not use `set -e` here: this file is sourced from CI before_script, and a
# failed plugin install must not abort the job before tools that did install
# can run.
#
# Split CI images keep asdf *code* at /opt/asdf and plugins/installs in
# $HOME/.asdf (ASDF_DATA_DIR). Never clone asdf into $HOME/.asdf when that
# path already holds plugin data — that shadows /opt/asdf/bin/asdf and
# produces `command-help.bash: No such file or directory`.
set +e
set -u

ASDF_VERSION="${ASDF_VERSION:-v0.14.1}"
TOOL_VERSIONS="${ASDF_TOOL_VERSIONS:-}"

_hosted_asdf_filter_path() {
  local out="" p
  local IFS=':'
  # shellcheck disable=SC2086
  for p in $PATH; do
    case "${p}" in
      /opt/asdf|/opt/asdf/*) continue ;;
    esac
    if [ -n "${out}" ]; then
      out="${out}:${p}"
    else
      out="${p}"
    fi
  done
  printf '%s' "${out}"
}

_hosted_asdf_export_path() {
  export PATH="${ASDF_DIR}/bin:${ASDF_DATA_DIR}/shims:$(_hosted_asdf_filter_path)"
  hash -r 2>/dev/null || true
}

# Flutter SDKs are .tar.xz. Split CI images may already have asdf at /opt/asdf
# so the later apt-get in install_asdf never runs — install unpack tools anyway.
_hosted_ensure_unpack_tools() {
  if command -v xz >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -qq
      apt-get install -y -qq git curl unzip xz-utils rsync ca-certificates
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq git curl unzip xz-utils rsync ca-certificates
    fi
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache git curl unzip xz rsync ca-certificates
  fi
}

install_asdf() {
  _hosted_ensure_unpack_tools
  if [ -x /opt/asdf/bin/asdf ]; then
    export ASDF_DIR="/opt/asdf"
    export ASDF_DATA_DIR="${HOME}/.asdf"
    mkdir -p "${ASDF_DATA_DIR}/shims" "${ASDF_DATA_DIR}/installs" "${ASDF_DATA_DIR}/plugins"
    _hosted_asdf_export_path
    echo "🤖 Using image asdf at ${ASDF_DIR} (data: ${ASDF_DATA_DIR})"
    return 0
  fi

  if [ -x /opt/homebrew/opt/asdf/bin/asdf ]; then
    export ASDF_DIR="/opt/homebrew/opt/asdf"
    export ASDF_DATA_DIR="${HOME}/.asdf"
    mkdir -p "${ASDF_DATA_DIR}/shims" "${ASDF_DATA_DIR}/installs" "${ASDF_DATA_DIR}/plugins"
    _hosted_asdf_export_path
    echo "🤖 Using Homebrew asdf at ${ASDF_DIR} (data: ${ASDF_DATA_DIR})"
    return 0
  fi

  if [ -x "${HOME}/.asdf/bin/asdf" ]; then
    export ASDF_DIR="${HOME}/.asdf"
    export ASDF_DATA_DIR="${HOME}/.asdf"
    _hosted_asdf_export_path
    echo "🤖 Using asdf at ${ASDF_DIR}"
    return 0
  fi

  if [ -e "${HOME}/.asdf" ] && [ ! -x "${HOME}/.asdf/bin/asdf" ]; then
    export ASDF_DIR="${HOME}/.asdf-vm"
    export ASDF_DATA_DIR="${HOME}/.asdf"
  else
    export ASDF_DIR="${HOME}/.asdf"
    export ASDF_DATA_DIR="${HOME}/.asdf"
  fi
  mkdir -p "${ASDF_DATA_DIR}"

  if [ -x "${ASDF_DIR}/bin/asdf" ]; then
    _hosted_asdf_export_path
    echo "🤖 Using asdf at ${ASDF_DIR} (data: ${ASDF_DATA_DIR})"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update -qq
      apt-get install -y -qq git curl unzip xz-utils rsync ca-certificates build-essential libssl-dev libreadline-dev zlib1g-dev
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq git curl unzip xz-utils rsync ca-certificates build-essential libssl-dev libreadline-dev zlib1g-dev
    fi
  fi

  echo "🤖 Installing asdf ${ASDF_VERSION} into ${ASDF_DIR}..."
  rm -rf "${ASDF_DIR}"
  git clone --depth 1 --branch "${ASDF_VERSION}" https://github.com/asdf-vm/asdf.git "${ASDF_DIR}"
  _hosted_asdf_export_path
}

if [ -z "${TOOL_VERSIONS}" ]; then
  if [ -n "${FULL_PROJECT_DIR:-}" ] && [ -f "${FULL_PROJECT_DIR}/.tool-versions" ]; then
    TOOL_VERSIONS="${FULL_PROJECT_DIR}/.tool-versions"
  elif [ -n "${CI_PROJECT_DIR:-}" ] && [ -f "${CI_PROJECT_DIR}/.tool-versions" ]; then
    TOOL_VERSIONS="${CI_PROJECT_DIR}/.tool-versions"
  elif [ -f "${PWD}/.tool-versions" ]; then
    TOOL_VERSIONS="${PWD}/.tool-versions"
  fi
fi

install_asdf

if [ -f "${ASDF_DIR}/asdf.sh" ]; then
  # shellcheck disable=SC1091
  . "${ASDF_DIR}/asdf.sh"
elif [ -f "${ASDF_DIR}/libexec/asdf.sh" ]; then
  # shellcheck disable=SC1091
  . "${ASDF_DIR}/libexec/asdf.sh"
fi
export ASDF_DIR ASDF_DATA_DIR
_hosted_asdf_export_path

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${ASDF_DIR}/bin" >> "${GITHUB_PATH}"
  echo "${ASDF_DATA_DIR}/shims" >> "${GITHUB_PATH}"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ASDF_DIR=${ASDF_DIR}" >> "${GITHUB_ENV}"
  echo "ASDF_DATA_DIR=${ASDF_DATA_DIR}" >> "${GITHUB_ENV}"
fi

ensure_plugin() {
  local name="$1"
  local url="${2:-}"
  if asdf plugin list 2>/dev/null | grep -qx "${name}"; then
    return 0
  fi
  if [ -n "${url}" ]; then
    asdf plugin add "${name}" "${url}"
  else
    asdf plugin add "${name}"
  fi
}

plugin_for_tool() {
  case "$1" in
    nodejs|node) echo nodejs ;;
    python) echo python ;;
    ruby) echo ruby ;;
    golang|go) echo golang ;;
    flutter) echo flutter ;;
    java) echo java ;;
    pnpm) echo pnpm ;;
    yarn) echo yarn ;;
    bun) echo bun ;;
    php) echo php ;;
    dart) echo dart ;;
    *) echo "$1" ;;
  esac
}

plugin_url() {
  case "$1" in
    java) echo "https://github.com/halcyon/asdf-java.git" ;;
    flutter) echo "https://github.com/asdf-community/asdf-flutter.git" ;;
    nodejs) echo "https://github.com/asdf-vm/asdf-nodejs.git" ;;
    python) echo "https://github.com/asdf-community/asdf-python.git" ;;
    ruby) echo "https://github.com/asdf-vm/asdf-ruby.git" ;;
    golang) echo "https://github.com/asdf-community/asdf-golang.git" ;;
    *) echo "" ;;
  esac
}

if ! command -v asdf >/dev/null 2>&1; then
  echo "❌ asdf is not on PATH after hosted setup (ASDF_DIR=${ASDF_DIR:-unset})"
  return 1 2>/dev/null || exit 1
fi

echo "🤖 asdf $(asdf --version 2>/dev/null || echo unknown)  ASDF_DIR=${ASDF_DIR}  ASDF_DATA_DIR=${ASDF_DATA_DIR}"

if [ -z "${TOOL_VERSIONS}" ] || [ ! -f "${TOOL_VERSIONS}" ]; then
  echo "⚠️ No .tool-versions found; skipping asdf install."
  asdf --version || true
  return 0 2>/dev/null || exit 0
fi

echo "🤖 Reading tools from ${TOOL_VERSIONS}"
_job_name="${CI_JOB_NAME:-${GITHUB_JOB:-}}"
_install_java=0
_install_ruby=0
case "${_job_name}" in
  *android*|*ios*|*macos*) _install_java=1 ;;
esac
case "${_job_name}" in
  *ios*|*macos*|*fastlane*|*publish*|*release*) _install_ruby=1 ;;
esac

_tool_dir="$(dirname "${TOOL_VERSIONS}")"
if [ -d "${_tool_dir}" ]; then
  cd "${_tool_dir}" || true
fi

_hosted_tool_versions="${_tool_dir}/.tool-versions.hosted"
: > "${_hosted_tool_versions}"

while IFS= read -r line || [ -n "${line:-}" ]; do
  tool="${line%% *}"
  rest="${line#"$tool"}"
  version="$(echo "$rest" | awk '{print $1}')"
  case "${tool}" in
    ''|\#*) continue ;;
  esac
  [ -n "${version}" ] || continue
  if [ "${_install_java}" -eq 0 ] && [ "${tool}" = "java" ]; then
    echo "ℹ️ Skipping asdf java on hosted Linux job ${_job_name}"
    continue
  fi
  if [ "${_install_ruby}" -eq 0 ] && [ "${tool}" = "ruby" ]; then
    echo "ℹ️ Skipping asdf ruby on hosted Linux job ${_job_name}"
    continue
  fi
  plugin="$(plugin_for_tool "${tool}")"
  url="$(plugin_url "${plugin}")"
  echo "🤖 asdf plugin ${plugin} (${tool} ${version})"
  ensure_plugin "${plugin}" "${url}"
  echo "🤖 asdf install ${plugin} ${version}"
  asdf install "${plugin}" "${version}"
  printf '%s %s\n' "${tool}" "${version}" >> "${_hosted_tool_versions}"
done < "${TOOL_VERSIONS}"

# Later script steps run `asdf current` / `asdf install` with set -e. Point them
# at the tools we actually installed so skipped ruby/java do not fail the job.
export ASDF_DEFAULT_TOOL_VERSIONS_FILENAME=".tool-versions.hosted"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ASDF_DEFAULT_TOOL_VERSIONS_FILENAME=.tool-versions.hosted" >> "${GITHUB_ENV}"
fi

asdf reshim || true
asdf current || true
if command -v git >/dev/null 2>&1; then
  # Flutter/SDK checkouts live outside CI_PROJECT_DIR; Git 2.35+ otherwise
  # aborts pub get with "detected dubious ownership" (exit 128).
  git config --global --add safe.directory '*' || true
  git config --global --add safe.directory "${ASDF_DATA_DIR}/installs" || true
fi
echo "✅ Hosted asdf setup done"
echo "🤖 which asdf=$(command -v asdf) which flutter=$(command -v flutter 2>/dev/null || echo none) which node=$(command -v node 2>/dev/null || echo none)"
