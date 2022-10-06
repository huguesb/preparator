#!/bin/bash

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
trap 'echo exit code: $? at ${BASH_SOURCE[0]}:${LINENO}' ERR

readonly att_root="$(cd "$( dirname "${BASH_SOURCE[0]}" )"/../../ && pwd)"

function err() { >&2 echo "$@" ; }

function usage() {
  err "Usage: preparator <command> <arguments....>"
  err
  err "Supported commands:"
  err " add <msg> [<cmd> | <path> | - ]"
  err " cherry-pick [<commit> | <first-commit> <last-commit>]"
  err " rebase [<new-base> [<branch>]]"
  err " amend <step>"
  err " edit <step> [<msg>] [<cmd> | <path> | - ]"

  exit 1
}

readonly cmd_prefix="preparator-command:"

function _ensure_repo_clean() {
  if ! git diff --quiet ; then
    err "Working copy has local changes!"
    err
    err "Please commit or stash your changes before adding a scripted step."
    exit 1
  fi
}

function _get_untracked_files() {
  git status --porcelain=v2 | grep -E '^\?' | sed -E 's/^\? //' | sort || true
}

function _apply() {
  msg="${1}"
  cmd="${2}"
  untracked0=$(_get_untracked_files)

  echo "Running:"
  echo "${cmd}"

  # run actual command
  bash -eu -c "${cmd}"

  untracked1=$(_get_untracked_files)

  new_untracked=$(diff <(echo "${untracked0}") <(echo "${untracked1}") | grep -E '^>' | sed -E 's/^> //' || true)
  if [[ -n "${new_untracked}" ]] ; then
    echo "The following new, non-ignored, files were created:"
    echo
    echo "${new_untracked}"
    echo
    echo "Do you want to add them to the new commit? [y/n]"
    echo

    while true ; do
      read answer
      case "$answer" in
        y|Y) git add ${new_untracked} ;;  # NB: no quotes! we want arg splitting!
        n|N) ;;
        *) echo "invalid answer."  ; continue ;;
      esac
      break
    done
  fi

  # add all tracked modified files to the commit
  git commit -a -m "${msg}"
}

function _command_from_arg() {
  if [[ "${1}" == "-" ]] || [[ -f "${1}" ]] ; then
    cat "${1}"
  else
    echo "${1}"
  fi
}

function _commit_message() {
  git show -s --format=%B "${1}"
}

function _is_scripted_step() {
  _commit_message "${1}" | grep -qE "^${cmd_prefix}$"
}

function _assemble_commit_message() {
  # assemble human-readable and machine-parsable commit message
  echo "
${1}

${cmd_prefix}
\`\`\`
${2}
\`\`\`
"
}

function _user_message_from_commit_message() {
  # extract user message from commit message
  # skip the last empty line before the "preparator-command:" prefix
  awk "/^$/ {lf=1} /^${cmd_prefix}"'$/ {exit} { if (plf) {printf '\n'} ; plf=lf ; print $0 }'
}

function _command_from_commit_message() {
  # extract command from commit message
  #  - skip everything before (and including) the "preparator-command:" prefix
  #  - skip "```" lines
  awk "/^${cmd_prefix}"'$/ {flag=1; next} /```/ {next} flag'
}

# selector format:
#  +n is a 0-based index from fork-point (excluded) of current branch with master
#  -n is a 0-based index from HEAD of current branch
#  otherwise assumed to be a commit-ish
function _commit_from_selector() {
  selector="${1}"
  if [[ "${1:0:1}" == '+' ]] ; then
    fork=$(git merge-base --fork-point master)
    # NB: the fork-point is excluded from this list
    commits=( $(git rev-list --reverse "${fork}..HEAD") )
    idx="${1:1}"
    if [[ "${idx}" -ge "${#commits[@]}" ]] ; then
      err "invalid selector: ${idx} [only ${#commits[@]} commits since fork-point]"
      exit 1
    fi
    echo "${commits[${idx}]}"
  elif [[ "${1:0:1}" == '-' ]] ; then
    git rev-parse "HEAD~${1:1}"
  else
    git rev-parse "${1}"
  fi
}

# execute a simple command (could be a function call, but not a pipe!)
# inside a temporary branch, with a specific commit checked out, and
# cherry-pick subsequent commits from the current branch
function _with_temp_branch() {
  commit="${1}"
  shift

  rand=$(openssl rand -hex 8)
  branch=$(git branch --show-current)
  tmp_branch="next-${branch}.${rand}"

  next_commit=$(git rev-list --reverse "${commit}..HEAD" | head -n1)

  # switch to temp branch
  git checkout -b "${tmp_branch}" "${commit}"

  # execute command
  "$@"

  # cherry-pick subsequent commits, if any
  if [[ -n "${next_commit}" ]] ; then
    cherry-pick "${next_commit}" "${branch}"
  fi

  # move temp branch over old branch
  git branch -M "${tmp_branch}" "${branch}"
}

function cherry-pick() {
  [[ $# -eq 1 ]] || [[ $# -eq 2 ]] || usage

  if [[ $# -eq 2 ]] ; then
    # list all commits between provided start and end, inclusive, from oldest to newest
    commits=( $(git rev-list --reverse "${1}^..${2}") )
  else
    commits=( "${1}" )
  fi

  for commit in "${commits[@]}" ; do
    # get raw commit message for the commit
    msg=$(_commit_message "${commit}")
    cmd=$(_command_from_commit_message <<<"${msg}")

    if [[ -z "${cmd}" ]] ; then
      echo "cherry-pick: ${commit}"
      git cherry-pick "${commit}"
    else
      echo "apply(${commit}): $(head -n 1 <<<"${msg}")"
      _apply "${msg}" "${cmd}"
    fi
  done
}

function add() {
  [[ $# -eq 2 ]] || usage

  _ensure_repo_clean

  cmd=$(_command_from_arg "${2}")
  msg=$(_assemble_commit_message "${1}" "${cmd}")

  _apply "${msg}" "${cmd}"
}

function rebase() {
  [[ $# -le 2 ]] || usage

  _ensure_repo_clean

  base=${1:-master}
  branch=${2:-$(git branch --show-current)}

  if [[ "${branch}" != "$(git branch --show-current)" ]]; then
    git checkout "${branch}"
  fi

  # TODO: make sure we deal with stacked scripted branches well
  # i.e given a scripted PR  based on a previous scripted PR,
  # rebasing the bottom PR on master and then the top PR on the bottom PR should Just Work(TM)
  # NB: this may require either explicit labeling of the start of each branch, or detecting and
  # skipping already-applied scripted steps

  if ! commit=$(git merge-base --fork-point "${base}" "${branch}") ; then
    err "ERROR: '${branch}' was not forked from '${base}'!"
    err "Consider the 'cherry-pick' command instead"
    exit 1
  fi
  _with_temp_branch "${commit}" true
}

function amend() {
  [[ $# -ge 1 ]] || usage

  commit=$(_commit_from_selector "${1}")
  shift

  if _is_scripted_step "${commit}" ; then
    err "ERROR: cannot 'amend' a scripted step!"
    err "Consider the 'edit' command instead"
    exit 1
  fi

  _with_temp_branch "${commit}" git commit --amend "$@"
}

function _edit_helper() {
  git reset --hard HEAD^
  _apply "${1}" "${2}"
}

function edit() {
  [[ $# -eq 2 ]] || [[ $# -eq 3 ]] || usage

  commit=$(_commit_from_selector "${1}")

  if ! _is_scripted_step "${commit}" ; then
    err "ERROR: cannot 'edit' a manual commit!"
    err "Consider the 'amend' command instead"
    exit 1
  fi

  _ensure_repo_clean

  if [[ $# -eq 2 ]] ; then
    user_msg=$(_commit_message "${commit}" | _user_message_from_commit_message)
    echo "reusing previous message: ${user_msg}"
  else
    user_msg="${2}"
    shift
  fi
  cmd=$(_command_from_arg "${2}")
  msg=$(_assemble_commit_message "${user_msg}" "${cmd}")

  _with_temp_branch "${commit}" _edit_helper "${msg}" "${cmd}"
}

if [[ $# -lt 1 ]] ; then
  usage
fi

cmd="${1}"
shift

case "${cmd}" in
  add|amend|cherry-pick|edit|rebase)
    ${cmd} "$@"
    ;;
  *)
    err "Unsupported command: \"${cmd}\""
    err
    usage
    ;;
esac
