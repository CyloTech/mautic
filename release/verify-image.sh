#!/bin/sh
# Release gate for an image built FROM the deployed digest with only the
# distribution's PHP packages upgraded (see the Dockerfile and
# release/image.env).
#
# Usage: release/verify-image.sh <image>
#
#   <image> is the release reference in release/image.env, or
#   local/<image>-trial:<tag> for a trial build.
#
# Exits 0 only when the local image passes every check and the authenticated
# registry definitively reports that the release tag does not exist yet. The
# registry check always targets the release tag, whatever image is tested.
# Any indeterminate registry answer fails.
#
# The PHP package floor is the Dockerfile's PHP_FIXED_VERSION default. A trial
# run may set another floor with GATE_TRIAL_PHP_MIN_VERSION (to prove the gate
# on today's unpatched packages). That variable is refused for the release
# image.
set -eu
LC_ALL=C
export LC_ALL

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

release_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(dirname "$release_dir")
for key in cylo_build_image cylo_build_release_ref cylo_build_dockerfile gate_base_ref \
    gate_php_source gate_php_extension_dir gate_web_server; do
    value=$(sed -n "s/^$key=//p" "$release_dir/image.env")
    case "$value" in ''|*[!A-Za-z0-9._/:@-]*) fail "release/image.env: bad or missing $key" ;; esac
    eval "$key=\$value"
done
case "$gate_php_source" in php[0-9].[0-9]) ;; *) fail "bad gate_php_source" ;; esac
case "$gate_web_server" in nginx|apache2) ;; *) fail "bad gate_web_server" ;; esac
gate_web_prepare=$(sed -n "s/^gate_web_prepare=//p" "$release_dir/image.env")
case "$gate_web_prepare" in ''|a2enmod-remoteip) ;; *) fail "release/image.env: bad gate_web_prepare" ;; esac

[ "$#" -eq 1 ] || fail "usage: $0 <image>"
image_ref=$1
trial_prefix="local/$cylo_build_image-trial:"
case "$image_ref" in
    "$cylo_build_release_ref") gate_mode=release ;;
    "$trial_prefix"*)
        case "${image_ref#"$trial_prefix"}" in
            ''|*[!A-Za-z0-9._-]*) fail "invalid trial tag: $image_ref" ;;
        esac
        gate_mode=trial
        ;;
    *) fail "unexpected image reference: $image_ref (expected $cylo_build_release_ref or $trial_prefix<tag>)" ;;
esac

php_floor=$(sed -n 's/^ARG PHP_FIXED_VERSION=//p' "$repo_dir/$cylo_build_dockerfile")
if [ -n "${GATE_TRIAL_PHP_MIN_VERSION:-}" ]; then
    [ "$gate_mode" = trial ] || fail "refusing GATE_TRIAL_PHP_MIN_VERSION for $image_ref"
    echo "TRIAL: PHP package floor set to $GATE_TRIAL_PHP_MIN_VERSION instead of the Dockerfile's '$php_floor'; this run cannot approve a release"
    php_floor=$GATE_TRIAL_PHP_MIN_VERSION
fi
case "$php_floor" in
    [0-9]*) ;;
    *) fail "PHP_FIXED_VERSION in $cylo_build_dockerfile is '$php_floor'; pin the fixed package version first" ;;
esac
case "$php_floor" in *[!A-Za-z0-9.+~-]*) fail "invalid PHP package floor: $php_floor" ;; esac

for tool in docker curl jq diff sort comm awk dpkg; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' INT TERM

in_image_as() {
    gate_image=$1
    gate_entrypoint=$2
    shift 2
    docker run --rm --platform linux/amd64 --network none --user 0:0 \
        -v "$release_dir:/release:ro" --entrypoint "$gate_entrypoint" "$gate_image" "$@"
}

echo "== Gate: $image_ref ($gate_mode), $gate_php_source floor $php_floor"

echo "== Registry: $cylo_build_release_ref must not exist"
registry=${cylo_build_release_ref%%/*}
repository_and_tag=${cylo_build_release_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || fail "release reference has no tag"
base_digest=${gate_base_ref#*@}
registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS --max-time 60 -K - -o "$work_dir/registry-body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}
api_status=$(registry_get /v2/) || fail "registry unreachable"
[ "$api_status" = 200 ] || fail "registry API check returned HTTP $api_status"
known_status=$(registry_get "/v2/$repository/manifests/$base_digest") || fail "registry unreachable"
[ "$known_status" = 200 ] || fail "registry read of the deployed digest returned HTTP $known_status; state is indeterminate"
manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$manifest_status" in
    200) fail "$cylo_build_release_ref already exists in the registry; refusing to replace it" ;;
    404)
        grep -q 'MANIFEST_UNKNOWN' "$work_dir/registry-body" \
            || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$work_dir/registry-body")"
        echo "deployed digest readable; $cylo_build_release_ref is definitively absent (MANIFEST_UNKNOWN)"
        ;;
    *) fail "registry returned HTTP $manifest_status for $cylo_build_release_ref" ;;
esac

echo "== Image identity"
docker image inspect "$image_ref" >/dev/null 2>&1 || fail "$image_ref is not a local image"
docker image inspect "$gate_base_ref" >/dev/null 2>&1 \
    || docker pull -q --platform linux/amd64 "$gate_base_ref" >/dev/null \
    || fail "cannot read the deployed image $gate_base_ref"
[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")" = linux/amd64 ] \
    || fail "image is not linux/amd64"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$gate_base_ref" | sed '/^$/d' > "$work_dir/base-layers"
docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" | sed '/^$/d' > "$work_dir/image-layers"
base_layer_count=$(wc -l < "$work_dir/base-layers")
image_layer_count=$(wc -l < "$work_dir/image-layers")
head -n "$base_layer_count" "$work_dir/image-layers" | cmp -s - "$work_dir/base-layers" \
    || fail "the deployed image's layers are not the start of the new image"
[ "$image_layer_count" -eq $((base_layer_count + 1)) ] \
    || fail "expected the deployed layers plus exactly one package layer; found $((image_layer_count - base_layer_count)) new layers"
echo "deployed layers ($base_layer_count) unchanged plus one package layer"
for field in '{{json .Config.Entrypoint}}' '{{json .Config.Cmd}}' '{{json .Config.User}}' \
    '{{json .Config.WorkingDir}}' '{{json .Config.ExposedPorts}}' '{{json .Config.Volumes}}' \
    '{{json .Config.Healthcheck}}' '{{json .Config.StopSignal}}' '{{json .Config.Shell}}' \
    '{{json .Config.Labels}}' '{{json .Config.Env}}' '{{json .Config.OnBuild}}'; do
    [ "$(docker image inspect --format "$field" "$image_ref")" = "$(docker image inspect --format "$field" "$gate_base_ref")" ] \
        || fail "image config $field differs from the deployed image"
done
echo "entrypoint, command, user, ports, volumes, labels and environment unchanged"

echo "== Reports (deployed, new)"
report_args="$gate_php_source $gate_php_extension_dir $gate_web_server $gate_web_prepare"
# shellcheck disable=SC2086
in_image_as "$gate_base_ref" sh /release/in-image-report.sh $report_args > "$work_dir/base.report" 2>&1 \
    || fail "report failed in the deployed image"
# shellcheck disable=SC2086
in_image_as "$image_ref" sh /release/in-image-report.sh $report_args > "$work_dir/image.report" 2>&1 \
    || fail "report failed in the new image"
section() {
    awk -v want="@@ $1" '$0 == want {on = 1; next} /^@@ / {on = 0} on' "$work_dir/$2.report"
}

echo "== Packages"
section packages base > "$work_dir/base.packages"
section packages image > "$work_dir/image.packages"
awk '{print $1}' "$work_dir/base.packages" > "$work_dir/base.names"
awk '{print $1}' "$work_dir/image.packages" > "$work_dir/image.names"
removed=$(comm -23 "$work_dir/base.names" "$work_dir/image.names")
added=$(comm -13 "$work_dir/base.names" "$work_dir/image.names")
[ -z "$removed" ] || fail "packages removed: $(echo $removed)"
[ -z "$added" ] || fail "packages added: $(echo $added)"
awk -v src="$gate_php_source" '$3 == src {print $1, $2}' "$work_dir/image.packages" > "$work_dir/php.packages"
[ -s "$work_dir/php.packages" ] || fail "no installed packages are built from $gate_php_source"
php_versions=$(awk '{print $2}' "$work_dir/php.packages" | sort -u)
[ "$(printf '%s\n' "$php_versions" | wc -l)" -eq 1 ] \
    || fail "$gate_php_source packages are not all at one version: $(echo $php_versions)"
dpkg --compare-versions "$php_versions" ge "$php_floor" \
    || fail "$gate_php_source $php_versions is older than the floor $php_floor"
base_php_version=$(awk -v src="$gate_php_source" '$3 == src {print $2; exit}' "$work_dir/base.packages")
echo "$(wc -l < "$work_dir/php.packages") $gate_php_source packages: $base_php_version -> $php_versions (floor $php_floor)"
sed 's/^/  /' "$work_dir/php.packages"
others=$(awk -v src="$gate_php_source" 'NR == FNR {v[$1] = $2; next} $3 != src && v[$1] != $2 {print "  " $1 " " v[$1] " -> " $2}' \
    "$work_dir/base.packages" "$work_dir/image.packages")
if [ -n "$others" ]; then
    echo "other packages upgraded as dependencies:"
    printf '%s\n' "$others"
else
    echo "no other package changed"
fi

echo "== PHP"
section version image

echo "== Shared libraries"
section missing-libraries image > "$work_dir/missing"
if [ -s "$work_dir/missing" ]; then
    cat "$work_dir/missing" >&2
    fail "PHP binaries or extensions have unresolved libraries"
fi
echo "PHP binaries and extensions resolve all libraries"

echo "== Modules"
for kind in modules-cli modules-fpm web-modules; do
    section "$kind" base > "$work_dir/base.$kind"
    section "$kind" image > "$work_dir/image.$kind"
    diff -u "$work_dir/base.$kind" "$work_dir/image.$kind" || fail "$kind differs from the deployed image"
done
if grep -qi -E 'warning|error' "$work_dir/image.modules-cli" "$work_dir/image.modules-fpm"; then
    fail "module listing printed warnings"
fi
echo "CLI, FPM and $gate_web_server module lists identical to the deployed image"

echo "== Configuration"
section php-config-files base > "$work_dir/base.conf"
section php-config-files image > "$work_dir/image.conf"
diff -u "$work_dir/base.conf" "$work_dir/image.conf" || fail "PHP configuration files changed"
echo "$(wc -l < "$work_dir/image.conf") PHP configuration files unchanged"
section config-tests image
section config-tests image | grep -qx 'php-fpm exit=0' || fail "php-fpm configuration test failed"
section config-tests image | grep -qx "$gate_web_server exit=0" || fail "$gate_web_server configuration test failed"

echo "== Multipart upload"
in_image_as "$image_ref" sh /release/multipart-smoke.sh "$gate_php_source" || fail "multipart upload smoke test failed"

echo "== Regression checks"
for check in "$release_dir"/regression/*.sh; do
    [ -e "$check" ] || continue
    echo "-- $(basename "$check")"
    in_image_as "$image_ref" sh "/release/regression/$(basename "$check")" \
        || fail "regression check $(basename "$check") failed"
done

echo "PASS ($gate_mode): $image_ref"
