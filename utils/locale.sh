#!/usr/bin/env bash
set -euo pipefail

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Normalize locale name by stripping encoding and modifier, and converting to lowercase.
normalize_locale_name() {
  local s="${1:-}"
  s="${s%%@*}"
  printf '%s\n' "$s" | tr '[:upper:]' '[:lower:]'
}

is_utf8_locale_name() {
  local n
  n="$(normalize_locale_name "${1:-}")"
  [[ "$n" =~ \.utf-?8$ ]]
}

apt_install_if_missing() {
  local pkg
  local missing=()

  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} > 0)); then
    # export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
  fi
}

ensure_locale_command() {
  if ! have_cmd locale; then
    apt_install_if_missing libc-bin
  fi

  if ! have_cmd locale; then
    echo "ERROR: 'locale' command is still unavailable after installing libc-bin." >&2
    return 1
  fi
}

list_available_locales() {
  locale -a 2>/dev/null || true
}

locale_exists() {
  local target normalized line
  target="$(normalize_locale_name "$1")"

  while IFS= read -r line; do
    normalized="$(normalize_locale_name "$line")"
    [[ "$normalized" == "$target" ]] && return 0
  done < <(list_available_locales)

  return 1
}

pick_utf8_locale_from_system() {
  local loc normalized
  local -a locales=()

  while IFS= read -r loc; do
    [[ -n "$loc" ]] && locales+=("$loc")
  done < <(list_available_locales)

  # First choice: C.UTF-8 / C.utf8
  for loc in "${locales[@]}"; do
    normalized="$(normalize_locale_name "$loc")"
    if [[ "$normalized" == "c.utf-8" || "$normalized" == "c.utf8" ]]; then
      printf '%s\n' "$loc"
      return 0
    fi
  done

  # Second choice: en_US.UTF-8 / en_US.utf8
  for loc in "${locales[@]}"; do
    normalized="$(normalize_locale_name "$loc")"
    if [[ "$normalized" == "en_us.utf-8" || "$normalized" == "en_us.utf8" ]]; then
      printf '%s\n' "$loc"
      return 0
    fi
  done

  # Third choice: any UTF-8 locale
  for loc in "${locales[@]}"; do
    if is_utf8_locale_name "$loc"; then
      printf '%s\n' "$loc"
      return 0
    fi
  done

  return 1
}

pick_environment_locale_if_valid() {
  local env_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"

  if [[ -n "$env_locale" ]] && is_utf8_locale_name "$env_locale" && locale_exists "$env_locale"; then
    printf '%s\n' "$env_locale"
    return 0
  fi

  return 1
}

generate_en_us_utf8_locale() {
  apt_install_if_missing locales

  if have_cmd locale-gen; then
    if [[ -f /etc/locale.gen ]]; then
      # Uncomment existing en_US.UTF-8 entry
      sudo sed -i \
        -e 's/^[[:space:]]*#\?[[:space:]]*en_US\.UTF-8[[:space:]]\+UTF-8[[:space:]]*$/en_US.UTF-8 UTF-8/' \
        /etc/locale.gen

      # If no en_US.UTF-8 entry exists, add one
      if ! grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' /etc/locale.gen; then
        echo 'en_US.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
      fi
    fi

    sudo locale-gen en_US.UTF-8
  else
    echo "ERROR: 'locale-gen' is unavailable even after installing locales." >&2
    return 1
  fi

  locale_exists "en_US.UTF-8"
}


# Check whether locale from environment variables is UTF-8
environment_utf8_locale() {
  local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ -n "$locale" && "$locale" =~ \.[Uu][Tt][Ff]-?8(@[A-Za-z]+)? ]]; then
    echo "$locale"
  else
    echo ""
  fi
}

# Main function to choose a valid UTF-8 locale
get_valid_utf8_locale() {
  local chosen

  ensure_locale_command

  # Use locale from environment if it's valid UTF-8
  if chosen="$(pick_environment_locale_if_valid)"; then
    echo "$chosen"
    return 0
  fi

  # Fallback to picking from system locales
  if chosen="$(pick_utf8_locale_from_system)"; then
    echo "$chosen"
    return 0
  fi

  # As a last resort, try to generate en_US.UTF-8
  generate_en_us_utf8_locale >/dev/null && echo "en_US.UTF-8"
}

# If the script is being run directly, print the chosen UTF-8 locale or an error message.
# shellcheck disable=SC2296
if [[ "${BASH_SOURCE[0]:-${(%):-%x}}" == "${0}" ]]; then
  if locale="$(get_valid_utf8_locale)"; then
    echo "$locale"
    exit 0
  else
    echo "ERROR: No valid UTF-8 locale found or could be generated." >&2
    exit 1
  fi
fi