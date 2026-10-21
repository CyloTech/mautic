# Releasing mautic 5.2.3-1

The image is the deployed mautic:latest digest with Ubuntu's php8.3 packages
upgraded in place (see Dockerfile.release).

## 1. Is the patched PHP available?

Ubuntu must have published a php8.3 for noble-security that carries the
fix for the multipart/form-data vulnerabilities announced on 21 October
2026. `8.3.6-0ubuntu0.24.04.13` (published 2026-10-21 13:41 UTC, patch
`CVE-2026-109618_109619.patch`, touches `main/rfc1867.c`) is that release.

    curl -s -G https://api.launchpad.net/1.0/ubuntu/+archive/primary \
      --data-urlencode ws.op=getPublishedSources --data-urlencode source_name=php8.3 \
      --data-urlencode distro_series=https://api.launchpad.net/1.0/ubuntu/noble \
      --data-urlencode pocket=Security --data-urlencode status=Published \
      --data-urlencode exact_match=true | jq -r '.entries[].source_package_version'

## 2-5. Pin, build, gate, push

From a clean checkout of branch `php-multipart-fix` on the Mac:

    git pull --ff-only origin php-multipart-fix
    release/build-on-builder.sh pin 8.3.6-0ubuntu0.24.04.13
    git commit -am "Require php8.3 8.3.6-0ubuntu0.24.04.13"
    git push origin php-multipart-fix
    release/build-on-builder.sh release

`release` builds `repo.cylo.net/mautic:5.2.3-1` on the builder from the
pushed commit, runs `release/verify-image.sh` and pushes only if the gate
passes, then prints the pushed digest.

A trial (never pushed) is `release/build-on-builder.sh trial <version>`.
