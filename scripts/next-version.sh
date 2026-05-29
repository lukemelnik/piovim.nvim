#!/usr/bin/env bash

set -o pipefail

usage() {
	cat <<'USAGE'
Usage: scripts/next-version.sh <patch|minor|major>

Print the next semver version based on VERSION.
USAGE
}

die() {
	local message=$1
	echo "error: $message" >&2
	exit 1
}

main() {
	local bump=${1:-}
	if [[ -z $bump || $bump == '-h' || $bump == '--help' ]]; then
		usage
		[[ -n $bump ]] && exit 0
		exit 1
	fi

	local current
	current=$(tr -d '[:space:]' < VERSION) || die 'failed to read VERSION'
	if [[ ! $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		die "VERSION must be a stable semver like 0.1.0, got: $current"
	fi

	local major=${BASH_REMATCH[1]}
	local minor=${BASH_REMATCH[2]}
	local patch=${BASH_REMATCH[3]}

	case $bump in
		patch)
			((patch++))
			;;
		minor)
			((minor++))
			patch=0
			;;
		major)
			((major++))
			minor=0
			patch=0
			;;
		*)
			die "unknown bump type: $bump"
			;;
	esac

	printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

main "$@"
