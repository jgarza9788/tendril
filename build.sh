#!/usr/bin/env bash
# Usage: ./build.sh [check|test|build|run|release|track]   (default: build)
#   check    type-check only
#   test     unit tests (tests/ and src/)
#   build    optimised binary in bin/tendril
#   run      build and launch
#   release  dist/tendril-<version>-linux-x86_64.tar.gz
#   track    bin/tendril-track: a build that prints a memory-leak report on exit
set -euo pipefail
cd "$(dirname "$0")"
ODIN=${ODIN:-odin}
VERSION=$(tr -d '[:space:]' < VERSION)
FLAGS=(-vet -strict-style -warnings-as-errors)
mkdir -p bin
case "${1:-build}" in
	check) "$ODIN" check src "${FLAGS[@]}" ;;
	test)  "$ODIN" test tests "${FLAGS[@]}" -out:bin/tests
	       # the app tests share the worker result queue, so they must not run in parallel
	       "$ODIN" test src "${FLAGS[@]}" -define:ODIN_TEST_THREADS=1 -out:bin/app_tests ;;
	build) "$ODIN" build src "${FLAGS[@]}" -o:speed -define:TENDRIL_VERSION="$VERSION" -out:bin/tendril ;;
	run)   "$ODIN" run src "${FLAGS[@]}" -o:speed -define:TENDRIL_VERSION="$VERSION" -out:bin/tendril ;;
	track) "$ODIN" build src "${FLAGS[@]}" -o:speed -define:TENDRIL_TRACK=true -define:TENDRIL_VERSION="$VERSION" -out:bin/tendril-track ;;
	release)
		"$ODIN" build src "${FLAGS[@]}" -o:speed -define:TENDRIL_VERSION="$VERSION" -out:bin/tendril
		name="tendril-$VERSION-linux-x86_64"
		rm -rf "dist/$name"; mkdir -p "dist/$name"
		cp bin/tendril README.md LICENSE "dist/$name/"
		tar -C dist -czf "dist/$name.tar.gz" "$name"
		echo "dist/$name.tar.gz" ;;
	*)     echo "unknown command: $1" >&2; exit 1 ;;
esac
