#!/bin/bash

ASP_VERSION=v8
ARCH_GIT_REPOS=(packages community)

OPT_ARCH=$(uname -m)
: "${ASPROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/asp}"
: "${ASPCACHE:=$ASPROOT/cache}"

log_meta() {
  # shellcheck disable=SC2059
  printf "$1 $2\\n" "${@:3}"
}

log_error() {
  log_meta 'error:' "$@" >&2
}

log_fatal() {
  log_error "$@"
  exit 1
}

log_warning() {
  log_meta 'warning:' "$@" >&2
}

log_info() {
  log_meta '==>' "$@"
}

map() {
  local map_r=0
  for _ in "${@:2}"; do
    "$1" "$_" || map_r=1
  done
  return $map_r
}

in_array() {
  local item needle=$1

  for item in "${@:2}"; do
    [[ $item = "$needle" ]] && return 0
  done

  return 1
}

quiet_git() {
  [[ $ASP_GIT_QUIET ]] && set -- "$1" -q "${@:2}"

  command git "$@"
}

__remote_refcache_update() {
  local remote=$1 cachefile=$ASPCACHE/remote-$remote refs

  refs=$(git ls-remote "$remote" 'refs/heads/packages/*') ||
      log_fatal "failed to update remote $remote"

  printf '%s' "$refs" |
      awk '{ sub(/refs\/heads\/packages\//, "", $2); print $2 }' >"$cachefile"
}

__remote_refcache_is_stale() {
  local now cachetime cachefile=$1 ttl=3600

  printf -v now '%(%s)T' -1

  # The cache is stale if we've exceeded the TTL.
  if ! cachetime=$(stat -c %Y "$cachefile" 2>/dev/null) ||
      (( now > (cachetime + ttl) )); then
    return 0
  fi

  # We also consider the cache to be stale when this script is newer than the
  # cache. This allows upgrades to asp to implicitly wipe the cache and not
  # make any guarantees about the file format.
  if (( $(stat -c %Y "${BASH_SOURCE[0]}" 2>/dev/null) > cachetime )); then
    return 0
  fi

  return 1
}

__remote_refcache_get() {
  local remote=$1 cachefile=$ASPCACHE/remote-$remote

  if __remote_refcache_is_stale "$cachefile"; then
    __remote_refcache_update "$remote"
  fi

  mapfile -t "$2" <"$cachefile"
}

remote_get_all_refs() {
  local remote=$1

  __remote_refcache_get "$remote" "$2"
}

remote_has_package() {
  local remote=$1 pkgname=$2 refs

  remote_get_all_refs "$remote" refs

  in_array "$pkgname" "${refs[@]}"
}

remote_is_tracking() {
  local repo=$1 pkgname=$2

  git show-ref -q "$repo/packages/$pkgname"
}

remote_get_tracked_refs() {
  local remote=$1

  mapfile -t "$2" < \
    <(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$remote")
}

remote_update_refs() {
  local remote=$1 refspecs=("${@:2}")

  quiet_git fetch "$remote" "${refspecs[@]}"
}

remote_update() {
  local remote=$1 refspecs

  remote_get_tracked_refs "$remote" refspecs

  # refuse to update everything
  [[ -z $refspecs ]] && return 0

  remote_update_refs "$remote" "${refspecs[@]}"
}

remote_untrack() {
  local remote=$1 pkgname=$2

  if git show-ref -q "refs/remotes/$remote/packages/$pkgname"; then
    git branch -dr "$remote/packages/$pkgname"
  fi
}

package_resolve() {
  local pkgbase

  [[ $pkgname ]] || log_fatal 'BUG: package_resolve called without pkgname var set'

  if package_find_remote "$1" "$2"; then
    return 0
  fi

  if pkgbase=$(archweb_get_pkgbase "$1") && package_find_remote "$pkgbase" "$2"; then
    log_info '%s is part of package %s' "$1" "$pkgbase"
    pkgname=$pkgbase
    return 0
  fi

  log_error 'unknown package: %s' "$pkgname"
  return 1
}

package_init() {
  local do_update=1

  if [[ $1 = -n ]]; then
    do_update=0
    shift
  fi

  pkgname=$1

  package_resolve "$pkgname" "$2" || return

  (( do_update )) || return 0

  remote_is_tracking "${!2}" "$pkgname" ||
      remote_update_refs "${!2}" "packages/$pkgname"
}

package_find_remote() {
  pkgname=$1

  # fastpath, checks local caches only
  for r in "${ARCH_GIT_REPOS[@]}"; do
    if remote_is_tracking "$r" "$pkgname"; then
      printf -v "$2" %s "$r"
      return 0
    fi
  done

  # slowpath, needs to talk to the remote
  for r in "${ARCH_GIT_REPOS[@]}"; do
    if remote_has_package "$r" "$pkgname"; then
      printf -v "$2" %s "$r"
      return 0
    fi
  done

  return 1
}

package_log() {
  local method=$2 logargs remote
  pkgname=$1

  package_init "$pkgname" remote || return

  case $method in
    shortlog)
      logargs=('--pretty=oneline')
      ;;
    difflog)
      logargs=('-p')
      ;;
    log)
      logargs=()
      ;;
    *)
      log_fatal 'BUG: unknown log method: %s' "$method"
      ;;
  esac

  git log "${logargs[@]}" "$remote/packages/$pkgname" -- trunk/
}

package_show_file() {
  local file=${2:-PKGBUILD} remote repo subtree
  pkgname=$1

  if [[ $pkgname = */* ]]; then
    IFS=/ read -r repo pkgname <<<"$pkgname"
  fi

  package_init "$pkgname" remote || return

  if [[ $file != */* ]]; then
    if [[ $repo ]]; then
      subtree=repos/$repo-$OPT_ARCH/
    else
      subtree=trunk/
    fi
  fi

  git show "remotes/$remote/packages/$pkgname:$subtree$file"
}

package_list_files() {
  local remote subtree=trunk
  pkgname=$1

  if [[ $pkgname = */* ]]; then
    IFS=/ read -r repo pkgname <<<"$pkgname"
  fi

  package_init "$pkgname" remote || return

  if [[ $repo ]]; then
    subtree=repos/$repo-$OPT_ARCH
  fi


  git ls-tree -r --name-only "remotes/$remote/packages/$pkgname" "$subtree" |
      awk -v "prefix=$subtree/" 'sub(prefix, "")'
}

package_export() {
  local remote repo arch=$OPT_ARCH arches subtree=trunk
  pkgname=$1

  if [[ $pkgname = */* ]]; then
    IFS=/ read -r repo pkgname <<<"$pkgname"
  fi

  package_init "$pkgname" remote || return

  if [[ $repo ]]; then
    mapfile -t arches < <(package_get_arches "$pkgname")
    if (( ${#arches[*]} == 1 )) && [[ ${arches[0]} = any ]]; then
      arch=any
    fi
    subtree=repos/$repo-$arch
  fi

  if ! git show "remotes/$remote/packages/$pkgname:$subtree/" &>/dev/null; then
    if [[ $repo ]]; then
      log_error "package '%s' not found in repo '%s-%s'" "$pkgname" "$repo" "$OPT_ARCH"
      return 1
    else
      log_error "package '%s' has no trunk directory!" "$pkgname"
      return 1
    fi
  fi

  mkdir "$pkgname" || return

  log_info 'exporting %s:%s' "$pkgname" "$subtree"
  git archive --format=tar "remotes/$remote/packages/$pkgname" "$subtree/" |
      tar --transform "s,^$subtree,$pkgname," -xf - "$subtree/"
}

package_checkout() {
  local remote
  pkgname=$1

  package_init "$pkgname" remote || return

  git show-ref -q "refs/heads/$remote/packages/$pkgname" ||
      git branch -qf --no-track {,}"$remote/packages/$pkgname"

  quiet_git clone \
    --shared \
    --single-branch \
    --branch "$remote/packages/$pkgname" \
    --config "pull.rebase=true" \
    "$ASPROOT" "$pkgname" || return
}

package_get_repos_with_arch() {
  local remote=$2 path arch repo
  pkgname=$1

  while read -r path; do
    path=${path##*/}
    repo=${path%-*}
    arch=${path##*-}
    printf '%s %s\n' "$repo" "$arch"
  done < <(git ls-tree --name-only "remotes/$remote/packages/$pkgname" repos/)
}

package_get_arches() {
  local remote arch
  declare -A arches
  pkgname=$1

  package_init "$pkgname" remote || return

  while read -r _ arch; do
    arches["$arch"]=1
  done < <(package_get_repos_with_arch "$pkgname" "$remote")

  printf '%s\n' "${!arches[@]}"
}

package_get_repos() {
  local remote repo
  declare -A repos
  pkgname=$1

  package_init "$pkgname" remote || return

  while read -r repo _; do
    repos["$repo"]=1
  done < <(package_get_repos_with_arch "$pkgname" "$remote")

  printf '%s\n' "${!repos[@]}"
}

package_untrack() {
  local remote=$2
  pkgname=$1

  if git show-ref -q "refs/heads/$remote/packages/$pkgname"; then
    git branch -D "$remote/packages/$pkgname"
  fi
}

archweb_get_pkgbase() {
  local pkgbase

  pkgbase=$(curl -LGs 'https://archlinux.org/packages/search/json/' --data-urlencode "q=$1" |
      jq -r --arg pkgname "$1" 'limit(1; .results[] | select(.pkgname == $pkgname).pkgbase)')
  [[ $pkgbase ]] || return

  printf '%s\n' "$pkgbase"
}


usage() {
  cat<<EOF
asp $ASP_VERSION [OPTIONS...] {COMMAND} ...

Manage build sources for Arch packages.

Options:
  -a           ARCH        Specify an architecture other than the host's
  -h                       Show this help
  -V                       Show package version

Package Commands:
  checkout           NAME...     Create a mutable git repository for packages
  difflog            NAME        Show revision history with diffs
  export             NAME...     Export packages
  list-all                       List all known packages
  list-arches        NAME...     List architectures for packages
  list-local                     List tracked packages
  list-repos         NAME...     List repos for packages
  log                NAME        Show revision history
  ls-files           NAME        List files for package
  shortlog           NAME        Show revision history in short form
  show               NAME [FILE] Show the PKGBUILD or other FILE
  untrack            NAME...     Remove a package from the local repository
  update             [NAME...]   Update packages (update all tracked if none specified)

Meta Commands:
  disk-usage                     Show amount of disk used by locally tracked packages
  gc                             Cleanup and optimize the local repository
  help                           Show this help
  set-git-protocol   PROTO       Change git protocol (one of: git, http, https)

EOF
}

__require_argc() {
  local min max argc=$2

  case $1 in
    *-)
      min=${1%-}
      ;;
    *-*)
      IFS=- read -r min max <<<"$1"
      ;;
    *)
      min=$1 max=$1
      ;;
  esac

  if (( min == max && argc != min )); then
    log_fatal '%s expects %d args, got %d' "${FUNCNAME[1]#action__}" "$min" "$argc"
  elif (( max && argc > max )); then
    log_fatal '%s expects at most %d args, got %d' "${FUNCNAME[1]#action__}" "$max" "$argc"
  elif (( argc < min )); then
    log_fatal '%s expects at least %d args, got %d' "${FUNCNAME[1]#action__}" "$min" "$argc"
  fi
}

version() {
  printf 'asp %s\n' "$ASP_VERSION"
}

update_all() {
  local r

  for r in "${ARCH_GIT_REPOS[@]}"; do
    log_info "updating remote '%s'" "$r"
    remote_update "$r"
  done
}

update_local_branches() {
  local r=0

  while read -r branchname; do
    git branch -qf "$branchname" "refs/remotes/$branchname" || r=1
  done < <(git branch --no-color)

  return "$r"
}

update_remote_branches() {
  local refspecs=() remote pkgname
  declare -A refspec_map

  if (( $# == 0 )); then
    update_all
    return
  fi

  # map packages to remotes
  for pkgname; do
    package_init -n "$pkgname" remote || return 1
    refspec_map["$remote"]+=" packages/$pkgname"
  done

  # update each remote all at once
  for remote in "${!refspec_map[@]}"; do
    read -ra refspecs <<<"${refspec_map["$remote"]}"
    remote_update_refs "$remote" "${refspecs[@]}"
  done
}

update_packages() {
  update_remote_branches "$@" && update_local_branches
}

initialize() {
  local remote url

  umask 0022

  export GIT_DIR=$ASPROOT/.git

  if [[ ! -f $ASPROOT/.asp ]]; then
    git init -q "$ASPROOT" || return 1
    for remote in "${ARCH_GIT_REPOS[@]}"; do
      git remote add "$remote" "https://github.com/archlinux/svntogit-$remote.git" || return 1
    done

    touch "$ASPROOT/.asp" || return 1
  else
    # migrate from git.archlinux.org to github.com
    for remote in "${ARCH_GIT_REPOS[@]}"; do
      url=$(git remote get-url "$remote")
      # https://github.blog/2021-09-01-improving-git-protocol-security-github/
      if [[ $url = *'git.archlinux.org'* ]] || [[ $url = *'git://github.com'* ]]; then
        git remote set-url "$remote" "https://github.com/archlinux/svntogit-$remote.git"
      fi
    done
  fi

  if [[ ! -d $ASPCACHE ]]; then
    mkdir -p "$ASPCACHE" || return 1
  fi

  return 0
}

dump_packages() {
  local remote refspecs dumpfn

  case $1 in
    all)
      dumpfn=remote_get_all_refs
      ;;
    local)
      dumpfn=remote_get_tracked_refs
      ;;
    *)
      log_fatal 'BUG: invalid dump type: "%s"' "$1"
      ;;
  esac

  for remote in "${ARCH_GIT_REPOS[@]}"; do
    "$dumpfn" "$remote" refspecs
    if [[ $refspecs ]]; then
      printf '%s\n' "${refspecs[@]##*/}"
    fi
  done | sort
}

list_local() {
  dump_packages 'local'
}

list_all() {
  dump_packages 'all'
}

shortlog() {
  package_log "$@" "${FUNCNAME[0]}"
}

log() {
  package_log "$@" "${FUNCNAME[0]}"
}

difflog() {
  package_log "$@" "${FUNCNAME[0]}"
}

gc() {
  git gc --prune=all
}

untrack() {
  local pkgname=$1 remote

  package_init -n "$pkgname" remote || return 1

  remote_untrack "$remote" "$pkgname"
  package_untrack "$pkgname" "$remote"
}

disk_usage() {
  local usage
  read -r usage _ < <(du -sh "$ASPROOT")

  log_info 'Using %s on disk.' "$usage"
}

action__checkout() {
  __require_argc 1- $#
  map package_checkout "$@"
}

action__difflog() {
  __require_argc 1 $#
  difflog "$1"
}

action__disk-usage() {
  __require_argc 0 $#
  disk_usage
}

action__export() {
  __require_argc 1- $#
  map package_export "$@"
}

action__gc() {
  __require_argc 0 $#
  gc
}

action__help() {
  __require_argc 0 $#
  usage
}

action__list-all() {
  __require_argc 0 $#
  list_all
}

action__list-arches() {
  __require_argc 1- $#
  map package_get_arches "$@"
}

action__list-local() {
  __require_argc 0 $#
  list_local
}

action__list-repos() {
  __require_argc 1- $#
  map package_get_repos "$@"
}

action__log() {
  __require_argc 1 $#
  log "$1"
}

action__shortlog() {
  __require_argc 1 $#
  shortlog "$1"
}

action__show() {
  __require_argc 1-2 $#
  package_show_file "$@"
}

action__untrack() {
  __require_argc 1- $#
  map untrack "$@"
}

action__update() {
  update_packages "$@"
}

action__ls-files() {
  __require_argc 1 $#

  package_list_files "$1"
}

action__set-git-protocol() {
  __require_argc 1 $#

  case $1 in
    git|http|https)
      ;;
    *)
      log_fatal 'invalid protocol: %s' "$1"
      ;;
  esac

  for remote in "${ARCH_GIT_REPOS[@]}"; do
    git remote set-url "$remote" "$1://github.com/archlinux/svntogit-$remote.git"
  done
}

dispatch_action() {
  local candidates

  [[ $1 ]] || log_fatal 'no action specified (use -h for help)'

  # exact match
  if declare -F "action__$1" &>/dev/null; then
    "action__$1" "${@:2}"
    return
  fi

  # prefix match
  mapfile -t candidates < <(compgen -A function "action__$1")
  case ${#candidates[*]} in
    0)
      log_fatal 'unknown action: %s' "$1"
      ;;
    1)
      "${candidates[0]}" "${@:2}"
      return
      ;;
    *)
      {
        printf "error: verb '%s' is ambiguous; possibilities:" "$1"
        printf " '%s'" "${candidates[@]#action__}"
        echo
      } >&2
      return 1
      ;;
  esac
}

initialize || log_fatal 'failed to initialize asp repository in %s' "$ASPROOT"

case $1 in
  --version)
    version
    exit 0
    ;;
  --help)
    usage
    exit 0
    ;;
esac

while getopts ':a:hV' flag; do
  case $flag in
    a)
      OPT_ARCH=$OPTARG
      ;;
    h)
      usage
      exit 0
      ;;
    V)
      version
      exit 0
      ;;
    \?)
      log_fatal "invalid option -- '%s'" "$OPTARG"
      ;;
    :)
      log_fatal "option '-%s' requires an argument" "$OPTARG"
      ;;
  esac
done
shift $(( OPTIND - 1 ))

dispatch_action "$@"
