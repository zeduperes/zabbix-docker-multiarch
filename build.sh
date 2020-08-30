#!/usr/bin/env bash

usage() {
  echo "$(basename "$0") TARGET [GITREF] [--push]"
}

get_latest_git_tag() {
  git tag -l | sort -n | tail -1
}

is_latest_git_tag() {
  [[ "$(get_latest_git_tag)" == "$1" ]]
}

get_current_git_commit() {
  git log --pretty=format:'%h' -n 1
}

version_major() {
  sed -rn 's/([0-9]+)\..*/\1/p' <<< "$1"
}

version_minor() {
  sed -rn 's/([0-9]+)\.([0-9]+).*/\1\.\2/p' <<< "$1"
}

is_latest_git_minor() {
  local major

  major=$(version_major "$1")
  [[ "$(git tag -l | grep '^'"${major}"'\.' | sort -n | tail -1)" == "$1" ]]
}

is_latest_git_patch() {
  local minor

  minor=$(version_minor "$1")
  [[ "$(git tag -l | grep '^'"${minor}"'\.' | sort -n | tail -1)" == "$1" ]]
}

get_available_architectures() {
  local image="$1"
  local tag="${2:-latest}"

  docker buildx imagetools inspect --raw "${image}:${tag}" | \
    jq -r '.manifests[].platform | .os + "/" + .architecture + "/" + .variant' | \
    sed 's#/$##' | sort
}

get_available_architectures_safe() {
  # FIXME Statically disabling archs should not be necessary...
  local all_archs

  all_archs=$(get_available_architectures "$@")
  if  [[ "$OS" == "centos" ]]
  then
    # grep -vE 'ppc64le|s390x|arm/v6|arm/v7' <<< "$all_archs"
    grep -vE 'arm/v6|arm/v7' <<< "$all_archs"
  else
  #   grep -vE 'ppc64le|s390x' <<< "$all_archs"
    echo "$all_archs"
  fi
}

get_image_labels() {
  local labels=("--label=built-by=zeduperes")
  if [[ "$TRAVIS" == "true" ]]
  then
    labels+=("--label=build-type=travis")
  elif [[ -n "$GITHUB_RUN_ID" ]]
  then
    labels+=("--label=build-type=github-actions" "--label=github-run-id=$GITHUB_RUN_ID")
  else
    labels+=("--label=build-type=manual" "--label=build-host=$HOSTNAME")
  fi
  echo "${labels[@]}"
}

get_tag_args() {
  local images=("$@")
  local tag_args=()
  for img in "${images[@]}"
  do
    tag_args+=("--tag $img")
  done
  echo "${tag_args[@]}"
}

git_setup() {
  local build_dir="$1"
  local git_ref="$2"

  if [[ -d "$build_dir" ]]
  then
    cd "$build_dir" || exit 9
    git clean -d -f -f
    git reset --hard HEAD
    git checkout master
    git pull
  else
    git clone https://github.com/zabbix/zabbix-docker "$build_dir"
    cd "$build_dir" || exit 9
  fi

  if [[ -z "$git_ref" ]]
  then
    git_ref="$(get_latest_git_tag)"
  fi

  git checkout "$git_ref" > /dev/null 2>&1
  # echo "$git_ref"
}

array_join() {
  local IFS="$1"
  shift
  echo "$*"
}

get_image_names() {
  local org=zeduperes
  local project_prefix=zabbix
  local project="$1"
  local os="$2"
  local git_ref="$3"
  local tag
  local images=()

  if [[ "$git_ref" == "master" ]]
  then
    tag=master
  else
    tag="$git_ref"
  fi

  if is_latest_git_tag "$git_ref"
  then
    # latest tag defaults to alpine-latest
    if [[ "$os" == "alpine" ]]
    then
      images+=("${org}/${project_prefix}-${project}:latest")
    fi
    images+=(
      "${org}/${project_prefix}-${project}:${os}-latest"
      "${org}/${project_prefix}-${project}-${os}:latest"
    )
  fi

  if is_latest_git_minor "$git_ref"
  then
    local major
    major=$(version_major "$git_ref")
    # latest tag defaults to alpine-latest
    if [[ "$os" == "alpine" ]]
    then
      images+=("${org}/${project_prefix}-${project}:${major}-latest")
    fi
    images+=(
      "${org}/${project_prefix}-${project}:${os}-${major}-latest"
      "${org}/${project_prefix}-${project}-${os}:${major}-latest"
    )
  fi

  if is_latest_git_patch "$git_ref"
  then
    local minor
    minor=$(version_minor "$git_ref")
    # latest tag defaults to alpine-latest
    if [[ "$os" == "alpine" ]]
    then
      images+=("${org}/${project_prefix}-${project}:${minor}-latest")
    fi
    images+=(
      "${org}/${project_prefix}-${project}:${os}-${minor}-latest"
      "${org}/${project_prefix}-${project}-${os}:${minor}-latest"
    )
  fi

  images+=(
    "${org}/${project_prefix}-${project}:${os}-$(get_current_git_commit)"
    "${org}/${project_prefix}-${project}:${os}-${tag}"
    "${org}/${project_prefix}-${project}-${os}:${tag}"
  )
  echo "${images[@]}"
}

_buildx() {
  # shellcheck disable=2206
  local platforms=($1)
  # shellcheck disable=2206
  local labels=($2)
  # shellcheck disable=2206
  local tag_args=($3)

  # shellcheck disable=2046,2068
  if [[ -n "$DRYRUN" ]]
  then
    echo docker buildx build \
      --platform "$(array_join "," "${platforms[@]}")" \
      --output "type=image,push=${PUSH_IMAGE}" \
      --no-cache \
      $(array_join " " "${labels[@]}") \
      ${tag_args[@]} .
  else
    docker buildx build \
      --platform "$(array_join "," "${platforms[@]}")" \
      --output "type=image,push=${PUSH_IMAGE}" \
      --no-cache \
      $(array_join " " "${labels[@]}") \
      ${tag_args[@]} .
    res="$?"
    if [[ "$res" == "0" ]]
    then
      echo "✔️ BUILD succeeded"
      echo "The following architectures have been pushed:"
      for platform in "${platforms[@]}"
      do
        echo "  - $platform"
      done
    else
      echo "❌ BUILD FAILED" >&2
    fi
    return "$res"
  fi
}

array_pop() {
  local val="$1"
  shift
  local array=("$@")
  local new_array=()
  local _tmp

  for _tmp in "${array[@]}"
  do
    if [[ "$_tmp" != "$val" ]]
    then
      new_array+=("$_tmp")
    fi
  done
  echo "${new_array[@]}"
}

disable_platforms() {
  # shellcheck disable=2206
  local del=($1)
  shift
  local platforms=("$@")
  local new_platforms=("$@")

  for item in "${del[@]}"
  do
    # shellcheck disable=2207
    new_platforms=($(array_pop "$item" "${new_platforms[@]}"))
  done
  echo "${new_platforms[@]}"
}

buildx_retry() {
  # shellcheck disable=2206
  local platforms=($1)
  # shellcheck disable=2206
  local labels=($2)
  # shellcheck disable=2206
  local tag_args=($3)
  local del

  # TODO Detect which architectures failed and retry build without them
  # TODO Don't retry if disable_platforms results in the same array
  # Step 1: all platforms

  if ! _buildx "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
  then
    if [[ -n "$NO_FALLBACK" ]]
    then
      echo "NO_FALLBACK is set: Skip fallback mechanism."
      return 7
    fi
    # Step 2: Disable i386, ppc64le and s390x
    del=(linux/386 linux/ppc64le linux/s390x)
    # shellcheck disable=2207
    platforms=($(disable_platforms "${del[*]}" "${platforms[@]}"))
    if ! _buildx "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
    then
      # Step 3: Disable armv6
      del=(linux/arm/v6)
      # shellcheck disable=2207
      platforms=($(disable_platforms "${del[*]}" "${platforms[@]}"))
      if ! _buildx "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
      then
        # Step 4: Disable armv7
        del=(linux/arm/v7)
        # shellcheck disable=2207
        platforms=($(disable_platforms "${del[*]}" "${platforms[@]}"))
        if ! _buildx "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
        then
          # Step 5: Disable aarch64
          del=(linux/arm64/v8)
          # shellcheck disable=2207
          platforms=($(disable_platforms "${del[*]}" "${platforms[@]}"))
          _buildx "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
        fi
      fi
    fi
  fi
}

build_project() {
  local project="$1"
  local os="$2"
  local git_ref="$3"
  local base_image
  local base_tag
  local images
  local platforms
  local labels
  local tag_args

  cd "$(readlink -f "$(dirname "$0")")" || exit 9
  local build_dir="${PWD}/data"

  git_setup "$build_dir" "$git_ref" > /dev/null 2>&1
  if [[ -z "$git_ref" ]]
  then
    git_ref="$(get_latest_git_tag)"
  fi

  if ! cd "${build_dir}/${project}/${os}" 2> /dev/null
  then
    echo "No such project/OS combination: ${project}/${os}" >&2
    exit 4
  fi

  # shellcheck disable=2207
  images=($(get_image_names "$project" "$os" "$git_ref"))

  echo "Building ${images[*]}"

  read -r base_image base_tag <<< \
    "$(sed -nr 's/^FROM\s+([^:]+):?((\w+).*)\s*$/\1 \3/p' Dockerfile | head -1)"

  echo "Upstream base image: $base_image (tag: $base_tag)"

  # shellcheck disable=2207
  platforms=($(get_available_architectures "$base_image" "$base_tag"))

  # Set build labels
  # shellcheck disable=2207
  labels=($(get_image_labels))

  # shellcheck disable=2207
  tag_args=($(get_tag_args "${images[@]}"))

  buildx_retry "${platforms[*]}" "${labels[*]}" "${tag_args[*]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  set -x

  if [[ "$#" -lt 1 ]]
  then
    usage
    exit 2
  fi

  case "$1" in
    -h|--help|h|help)
      usage
      exit 0
      ;;
  esac

  TARGET="$1"
  # Defaults
  PUSH_IMAGE=false

  case "$2" in
    -f|--force|-p|--push)
      PUSH_IMAGE=true
      ;;
    *)
      GIT_REF="$2"
      case "$3" in
        -f|--force|-p|--push)
          PUSH_IMAGE=true
          ;;
      esac
      ;;
  esac

  if ! docker buildx version >/dev/null
  then
    echo "buildx is not available" >&2
    exit 99
  fi

  read -r PROJECT OS <<< "$(sed -r 's/(.+)-(.+)/\1 \2/' <<< "$TARGET")"

  # Default to alpine
  if [[ -z "$OS" ]]
  then
    OS=alpine
  fi

  build_project "$PROJECT" "$OS" "$GIT_REF"
fi

# vim set et ts=2 sw=2 :
