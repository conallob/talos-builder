#!/usr/bin/env bash
# Release helper: pick a Talos tag, bump TALOS_VERSION if needed, push the tag to trigger CI.
set -euo pipefail

TALOS_REPO="siderolabs/talos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEFILE="$SCRIPT_DIR/Makefile"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

current_makefile_value() { grep "^$1" "$MAKEFILE" | awk '{print $3}'; }

fetch_stable_releases() {
    local json
    json="$(curl -sf \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${TALOS_REPO}/releases?per_page=${1:-10}")" \
        || die "Failed to reach GitHub API — check internet connection or rate limit."
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if not r.get('prerelease') and not r.get('draft'):
        print(r['tag_name'])"
    else
        die "jq or python3 is required to parse the GitHub API response"
    fi
}

update_makefile_talos_version() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^TALOS_VERSION = .*/TALOS_VERSION = $1/" "$MAKEFILE"
    else
        sed -i "s/^TALOS_VERSION = .*/TALOS_VERSION = $1/" "$MAKEFILE"
    fi
}

actions_url() {
    local remote
    remote="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
    remote="${remote%.git}"
    remote="${remote/git@github.com:/https://github.com/}"
    echo "${remote}/actions"
}

# ── pre-flight checks ────────────────────────────────────────────────────────

[[ -f "$MAKEFILE" ]] || die "Makefile not found at $MAKEFILE"

branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "main" ]] || die "Must be on main branch (currently on '$branch')"

if ! git -C "$SCRIPT_DIR" diff --quiet || ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
    die "Working tree has uncommitted changes — commit or stash them first."
fi

# ── resolve target tag ───────────────────────────────────────────────────────

chosen_tag=""

if [[ $# -ge 1 ]]; then
    chosen_tag="$1"
else
    echo "Fetching recent Talos releases..."
    tags=()
    while IFS= read -r tag; do tags+=("$tag"); done < <(fetch_stable_releases 10)
    [[ ${#tags[@]} -gt 0 ]] || die "No stable releases found."

    echo ""
    echo "Recent Talos releases:"
    for i in "${!tags[@]}"; do
        printf "  %2d.  %s\n" "$((i+1))" "${tags[$i]}"
    done
    echo ""
    read -rp "Select release [1]: " selection
    selection="${selection:-1}"
    [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#tags[@]} )) \
        || die "Invalid selection '$selection'"
    chosen_tag="${tags[$((selection-1))]}"
fi

[[ "$chosen_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'$chosen_tag' is not a stable release tag (expected vX.Y.Z)"

# ── compare with current Makefile versions ───────────────────────────────────

current_talos="$(current_makefile_value TALOS_VERSION)"
current_pkg="$(current_makefile_value PKG_VERSION)"
need_commit=false

echo ""
echo "Current:  TALOS_VERSION = $current_talos  |  PKG_VERSION = $current_pkg"
echo "Target:   TALOS_VERSION = $chosen_tag"

if [[ "$chosen_tag" == "$current_talos" ]]; then
    echo ""
    echo "TALOS_VERSION is already $chosen_tag."
else
    # Detect minor/major bump (vX.Y differs)
    cur_mm="${current_talos%.*}"
    new_mm="${chosen_tag%.*}"
    if [[ "$cur_mm" != "$new_mm" ]]; then
        cat <<-WARN

		WARNING: minor/major version bump detected ($current_talos → $chosen_tag).

		Before releasing you must verify manually:
		  1. Patches apply cleanly:
		       make clean checkouts patches
		  2. PKG_VERSION is correct for the RPi kernel's Linux major.minor.
		       Current PKG_VERSION = $current_pkg
		       See CLAUDE.md "Find the right PKG_VERSION" for guidance.

		WARN
        read -rp "Have you verified patches and PKG_VERSION? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }
    fi

    update_makefile_talos_version "$chosen_tag"
    need_commit=true
fi

# ── check tag doesn't already exist ─────────────────────────────────────────

if git -C "$SCRIPT_DIR" tag --list "$chosen_tag" | grep -q .; then
    [[ "$need_commit" == true ]] && git -C "$SCRIPT_DIR" checkout -- "$MAKEFILE"
    die "Local tag '$chosen_tag' already exists. Remove with: git tag -d $chosen_tag"
fi

if git -C "$SCRIPT_DIR" ls-remote --tags origin "refs/tags/$chosen_tag" | grep -q .; then
    [[ "$need_commit" == true ]] && git -C "$SCRIPT_DIR" checkout -- "$MAKEFILE"
    die "Remote tag '$chosen_tag' already exists — CI may already have run for this release."
fi

# ── confirm and execute ───────────────────────────────────────────────────────

echo ""
echo "Will:"
[[ "$need_commit" == true ]] && echo "  • commit TALOS_VERSION = $chosen_tag to main and push"
echo "  • create and push tag $chosen_tag  →  triggers CI build + GitHub Release"
echo ""
read -rp "Proceed? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
    [[ "$need_commit" == true ]] && git -C "$SCRIPT_DIR" checkout -- "$MAKEFILE"
    echo "Aborted."
    exit 0
fi

if [[ "$need_commit" == true ]]; then
    git -C "$SCRIPT_DIR" add "$MAKEFILE"
    git -C "$SCRIPT_DIR" commit -m "Bump TALOS_VERSION to $chosen_tag"
    git -C "$SCRIPT_DIR" push origin main
fi

git -C "$SCRIPT_DIR" tag "$chosen_tag"
git -C "$SCRIPT_DIR" push origin "$chosen_tag"

echo ""
echo "Done. Tag $chosen_tag pushed — CI build is now running."
echo "Monitor: $(actions_url)"
