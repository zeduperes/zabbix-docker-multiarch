#!/usr/bin/env bash

list_targets() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone -q --depth 1 https://github.com/zabbix/zabbix-docker "$tmpdir"
  find "$tmpdir" -maxdepth 5 -mindepth 5 -type d | grep -v .git | \
    sed -e "s|^${tmpdir}/||" -e 's|/|-|'
  trap "rm -rf \"$tmpdir\"" EXIT
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  cd "$(readlink -f "$(dirname "$0")")" || exit 9

  for target in $(list_targets)
  do
    echo "# BUILD $target"
    ./build.sh "$target" -p
  done
fi
