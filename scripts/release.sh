#!/usr/bin/env bash

set -o pipefail

usage() {
	cat <<'USAGE'
Usage: scripts/release.sh <version> [--dry-run] [--push-tag]

Prepare and tag a semver release.

Arguments:
  version      Semver version, with or without leading v, e.g. 0.1.0

Options:
  --dry-run    Show what would happen without changing files or tags
  --push-tag   Push the created tag to origin after tagging
  -h, --help   Show this help

The script requires a clean working tree before it starts. It updates VERSION
and lua/piovim/version.lua, runs local checks, commits changed version files,
and creates an annotated git tag named v<version>.
USAGE
}

die() {
	local message=$1
	echo "error: $message" >&2
	exit 1
}

run() {
	printf '+'
	printf ' %q' "$@"
	printf '\n'
	"$@"
	local status=$?
	if ((status != 0)); then
		die "command failed with exit code $status"
	fi
}

normalize_version() {
	local input=$1
	input=${input#v}
	if [[ ! $input =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
		die "version must be semver, e.g. 0.1.0"
	fi
	echo "$input"
}

ensure_clean_tree() {
	local status
	status=$(git status --porcelain)
	if [[ -n $status ]]; then
		echo "$status" >&2
		die 'working tree must be clean before releasing'
	fi
}

ensure_tag_available() {
	local tag=$1
	if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
		die "tag already exists: $tag"
	fi
}

write_version_files() {
	local version=$1
	printf '%s\n' "$version" > VERSION
	printf 'return "%s"\n' "$version" > lua/piovim/version.lua
}

run_checks() {
	local lua_files
	lua_files=(lua/piovim/*.lua scripts/smoke.lua scripts/review_diff_tests.lua)

	run git diff --check
	run luac -p "${lua_files[@]}"
	run nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-c 'lua require("piovim").setup({ keys = {} })' \
		-c qa
	run nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-S scripts/smoke.lua \
		-c qa
	run nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-S scripts/review_diff_tests.lua \
		-c qa
}

commit_version_if_needed() {
	local version=$1
	local status
	status=$(git status --porcelain -- VERSION lua/piovim/version.lua)
	if [[ -z $status ]]; then
		echo "version files already at $version"
		return
	fi

	run git add VERSION lua/piovim/version.lua
	run git commit -m "chore(release): v$version"
}

main() {
	local version_arg=${1:-}
	local dry_run=false
	local push_tag=false

	if [[ -z $version_arg ]]; then
		usage
		exit 1
	fi
	shift

	while (($# > 0)); do
		case $1 in
			--dry-run)
				dry_run=true
				;;
			--push-tag)
				push_tag=true
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown option: $1"
				;;
		esac
		shift
	done

	local version
	version=$(normalize_version "$version_arg")
	local tag="v$version"
	local repo_root
	repo_root=$(git rev-parse --show-toplevel) || die 'not inside a git repo'
	cd "$repo_root" || die "failed to cd to $repo_root"

	ensure_tag_available "$tag"

	if $dry_run; then
		echo "Would release $tag from $repo_root"
		echo 'Would require a clean working tree'
		echo 'Would update VERSION and lua/piovim/version.lua'
		echo 'Would run local checks'
		echo "Would commit version files if changed"
		echo "Would create annotated tag $tag"
		if $push_tag; then
			echo "Would push tag $tag to origin"
		fi
		exit 0
	fi

	ensure_clean_tree
	write_version_files "$version"
	run_checks
	commit_version_if_needed "$version"
	run git tag -a "$tag" -m "piovim.nvim $tag"

	echo "Created $tag."
	if $push_tag; then
		run git push origin "$tag"
	else
		echo "Push the tag with: git push origin $tag"
	fi
}

main "$@"
