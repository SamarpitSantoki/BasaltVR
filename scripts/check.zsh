#!/bin/zsh

set -euo pipefail

readonly script_dir=${0:A:h}
readonly repo_dir=${script_dir:h}
cd "$repo_dir"

run_step() {
    local title=$1
    shift
    print
    print "==> $title"
    "$@"
}

run_step "Environment" "$script_dir/doctor.zsh" --core

print
print "==> Repository hygiene"
zsh -n packaging/*.zsh runtime/scripts/*.zsh scripts/*.zsh
plutil -lint packaging/Info.plist
swift package --package-path streamer dump-package >/dev/null
(
    ruby -e '
        require "yaml"
        Dir[".github/**/*.{yml,yaml}"].sort.each { |path| YAML.load_file(path) }
    '
)
"$script_dir/check-markdown-links.zsh"
git diff --check

ignored_tracked=$(git ls-files -ci --exclude-standard)
if [[ -n "$ignored_tracked" ]]; then
    print -u2 "Ignored development artifacts are tracked:"
    print -rC1 -- "${(@f)ignored_tracked}" >&2
    exit 1
fi
print "PASS: scripts, metadata, package manifest, and tracked-file hygiene"

run_step "Swift tests" swift test --package-path streamer
run_step "Apple Silicon release build" \
    swift build -c release --arch arm64 --package-path streamer

print
print "PASS: contributor checks completed"
