#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="WP Media Uploader"
PROJECT_PATH="WordpressMediaUploader.xcodeproj"
SCHEME="WordpressMediaUploader"
ENTITLEMENTS_PATH="Sources/WordpressImageUploaderApp/WPMediaUploader.entitlements"

DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-Developer ID Application: David Degner (Q26G342EEL)}"
# Default to the historical local profile name used for notarization on this repo.
# Override by setting NOTARY_KEYCHAIN_PROFILE explicitly.
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-notary-profile}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
PUBLISH_GITHUB_RELEASE="${PUBLISH_GITHUB_RELEASE:-1}"
PUBLISH_GITHUB_PACKAGE="${PUBLISH_GITHUB_PACKAGE:-1}"
GITHUB_REPO="${GITHUB_REPO:-}"
github_release_url=""
github_package_ref=""

notify() {
    local message="$1"
    /usr/bin/osascript -e "display notification \"${message}\" with title \"WP Media Uploader\"" >/dev/null 2>&1 || true
}

resolve_github_repo() {
    local origin_url
    if [[ -n "$GITHUB_REPO" ]]; then
        echo "$GITHUB_REPO"
        return 0
    fi

    origin_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -z "$origin_url" ]]; then
        return 1
    fi

    case "$origin_url" in
        git@github.com:*)
            origin_url="${origin_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            origin_url="${origin_url#ssh://git@github.com/}"
            ;;
        https://github.com/*)
            origin_url="${origin_url#https://github.com/}"
            ;;
        *)
            return 1
            ;;
    esac

    origin_url="${origin_url%.git}"
    echo "$origin_url"
}

ensure_tag_matches_head() {
    local tag_name="$1"
    local head_commit
    local tag_commit

    head_commit="$(git rev-parse HEAD)"
    if git rev-parse -q --verify "refs/tags/${tag_name}" >/dev/null; then
        tag_commit="$(git rev-list -n 1 "$tag_name")"
        if [[ "$tag_commit" != "$head_commit" ]]; then
            echo "ERROR: Tag ${tag_name} points to ${tag_commit}, not HEAD ${head_commit}."
            exit 1
        fi
    else
        echo "==> Creating git tag ${tag_name}"
        git tag -a "$tag_name" -m "${tag_name} release"
    fi
}

ensure_remote_tag_matches_head() {
    local tag_name="$1"
    local head_commit
    local remote_tag_commit

    head_commit="$(git rev-parse HEAD)"
    remote_tag_commit="$(git ls-remote --tags origin "refs/tags/${tag_name}^{}" | awk '{print $1}' | head -n1)"
    if [[ -z "$remote_tag_commit" ]]; then
        remote_tag_commit="$(git ls-remote --tags origin "refs/tags/${tag_name}" | awk '{print $1}' | head -n1)"
    fi

    if [[ -n "$remote_tag_commit" ]]; then
        if [[ "$remote_tag_commit" != "$head_commit" ]]; then
            echo "ERROR: Remote tag ${tag_name} points to ${remote_tag_commit}, not HEAD ${head_commit}."
            exit 1
        fi
        echo "==> Remote tag ${tag_name} already points at HEAD"
    else
        echo "==> Pushing git tag ${tag_name}"
        git push origin "refs/tags/${tag_name}"
    fi
}

write_release_notes() {
    local version="$1"
    local notes_path="$2"

    if [[ -f CHANGELOG.md ]]; then
        awk -v version="$version" '
            $0 ~ "^## \\[" version "\\]" { in_section = 1; next }
            in_section && /^## \[/ { exit }
            in_section { print }
        ' CHANGELOG.md > "$notes_path"
    fi

    if [[ ! -s "$notes_path" ]]; then
        cat > "$notes_path" <<EOF
Release v${version}

- Developer ID signed and notarized macOS binary.
EOF
    fi
}

publish_github_release() {
    local version="$1"
    local final_zip="$2"
    local sha_file="$3"
    local tag_name="v${version}"
    local repo_slug
    local notes_path

    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: GitHub CLI (gh) is required for release publishing."
        echo "Install gh or set PUBLISH_GITHUB_RELEASE=0."
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: GitHub CLI is not authenticated."
        echo "Run 'gh auth login' or set PUBLISH_GITHUB_RELEASE=0."
        exit 1
    fi

    repo_slug="$(resolve_github_repo || true)"
    if [[ -z "$repo_slug" ]]; then
        echo "ERROR: Could not determine GitHub repo slug from origin."
        echo "Set GITHUB_REPO=owner/repo and retry."
        exit 1
    fi

    ensure_tag_matches_head "$tag_name"
    ensure_remote_tag_matches_head "$tag_name"

    notes_path="${release_dir}/release-notes.md"
    write_release_notes "$version" "$notes_path"

    echo "==> Publishing GitHub Release ${tag_name}"
    if gh release view "$tag_name" --repo "$repo_slug" >/dev/null 2>&1; then
        gh release upload "$tag_name" "$final_zip" "$sha_file" --repo "$repo_slug" --clobber
        gh release edit "$tag_name" --repo "$repo_slug" --title "WP Media Uploader v${version}" --notes-file "$notes_path" --latest
    else
        gh release create "$tag_name" "$final_zip" "$sha_file" --repo "$repo_slug" --title "WP Media Uploader v${version}" --notes-file "$notes_path" --latest
    fi

    github_release_url="$(gh release view "$tag_name" --repo "$repo_slug" --json url -q .url)"
}

publish_github_package() {
    local version="$1"
    local final_zip="$2"
    local sha_file="$3"
    local tag_name="v${version}"
    local owner

    if ! command -v oras >/dev/null 2>&1; then
        echo "ERROR: oras is required for package publishing. Install with: brew install oras"
        echo "Or set PUBLISH_GITHUB_PACKAGE=0."
        exit 1
    fi

    # Resolve owner from repo slug or git remote
    local repo_slug
    repo_slug="$(resolve_github_repo || true)"
    if [[ -z "$repo_slug" ]]; then
        echo "ERROR: Could not determine GitHub repo slug from origin."
        echo "Set GITHUB_REPO=owner/repo and retry."
        exit 1
    fi
    owner="$(echo "${repo_slug%%/*}" | tr '[:upper:]' '[:lower:]')"

    local ref="ghcr.io/${owner}/wp-media-uploader:${tag_name}"

    echo "==> Publishing GitHub Package ${ref}"

    # Authenticate oras using Docker credential store (populated by gh auth token | docker login)
    local docker_config="$HOME/.docker/config.json"
    if [[ ! -f "$docker_config" ]] || ! grep -q "ghcr.io" "$docker_config" 2>/dev/null; then
        gh auth token | docker login ghcr.io -u "$owner" --password-stdin
    fi

    # Push zip and sha256 as an OCI artifact; run from a temp dir to avoid absolute-path errors
    local pkg_staging
    pkg_staging="$(mktemp -d)"
    cp "$final_zip" "${pkg_staging}/"
    cp "$sha_file" "${pkg_staging}/sha256.txt"

    (
        cd "$pkg_staging"
        oras push "$ref" \
            --registry-config "$docker_config" \
            --image-spec v1.1 \
            "$(basename "$final_zip"):application/zip" \
            "sha256.txt:text/plain" \
            --annotation "org.opencontainers.image.source=https://github.com/${repo_slug}" \
            --annotation "org.opencontainers.image.version=${tag_name}"
    )

    rm -rf "$pkg_staging"
    github_package_ref="$ref"
}

trap 'notify "Distribution build failed"' ERR

version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
build_number="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"

if [[ -z "$version" || -z "$build_number" ]]; then
    echo "ERROR: Could not read version/build from project.yml"
    exit 1
fi

release_dir="output/release/v${version}"
derived_data_path="${release_dir}/DerivedData"
app_path="${derived_data_path}/Build/Products/Release/${APP_NAME}.app"
submit_zip="${release_dir}/WPMediaUploader-v${version}-submit.zip"
final_zip="WPMediaUploader-v${version}-macOS.zip"

mkdir -p "$release_dir"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release app (unsigned build output)"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build | tee "${release_dir}/build.log"

if [[ ! -d "$app_path" ]]; then
    echo "ERROR: Expected app not found at: $app_path"
    exit 1
fi

# Sign inside-out (nested helper first, then the bundle). --deep is
# unsupported for distribution signing and would stamp the app's
# entitlements onto the helper.
echo "==> Signing app with Developer ID (inside-out)"
HELPER_PATH="${app_path}/Contents/MacOS/avifenc"
HELPER_ENTITLEMENTS_PATH="Sources/WordpressImageUploaderApp/AvifencHelper.entitlements"
if [[ -f "$HELPER_PATH" ]]; then
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$HELPER_ENTITLEMENTS_PATH" \
        --sign "$DEVELOPER_ID_APP_CERT" \
        "$HELPER_PATH"
fi

codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$DEVELOPER_ID_APP_CERT" \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

echo "==> Creating notarization archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submit_zip"

echo "==> Submitting to Apple notarization service"
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$submit_zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait | tee "${release_dir}/notary.log"
elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    xcrun notarytool submit \
        "$submit_zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait | tee "${release_dir}/notary.log"
else
    echo "ERROR: Notary credentials are missing."
    echo "Set NOTARY_KEYCHAIN_PROFILE, or set APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD."
    exit 1
fi

echo "==> Stapling notarization ticket"
staple_attempts=12
staple_delay_seconds=10
stapled=0

for ((attempt = 1; attempt <= staple_attempts; attempt++)); do
    echo "Staple attempt ${attempt}/${staple_attempts}"
    if xcrun stapler staple -v "$app_path"; then
        xcrun stapler validate -v "$app_path"
        stapled=1
        break
    fi
    if (( attempt < staple_attempts )); then
        echo "Stapling failed, retrying in ${staple_delay_seconds}s..."
        sleep "$staple_delay_seconds"
    fi
done

if (( stapled == 0 )); then
    echo "ERROR: Failed to staple notarization ticket after ${staple_attempts} attempts."
    exit 1
fi

echo "==> Creating final distribution archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_zip"
shasum -a 256 "$final_zip" | tee "${release_dir}/sha256.txt"

echo "==> Distribution build complete"
echo "Version: $version ($build_number)"
echo "Archive: $final_zip"

if [[ "$PUBLISH_GITHUB_RELEASE" == "1" ]]; then
    publish_github_release "$version" "$final_zip" "${release_dir}/sha256.txt"
    echo "GitHub Release: ${github_release_url}"
else
    echo "GitHub Release: skipped (PUBLISH_GITHUB_RELEASE=${PUBLISH_GITHUB_RELEASE})"
fi

if [[ "$PUBLISH_GITHUB_PACKAGE" == "1" ]]; then
    publish_github_package "$version" "$final_zip" "${release_dir}/sha256.txt"
    echo "GitHub Package: ${github_package_ref}"
else
    echo "GitHub Package: skipped (PUBLISH_GITHUB_PACKAGE=${PUBLISH_GITHUB_PACKAGE})"
fi

notify "Distribution build v${version} is ready"
