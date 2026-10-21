#!/bin/sh
# Runs inside an image (mounted read-only at /release). Prints the package and
# PHP facts that release/verify-image.sh compares between the deployed image
# and the new image.
#
# Usage: in-image-report.sh <php source package> <PHP extension directory> <web server: nginx|apache2> [<web prepare>]
#
# <web prepare> is optional and only "a2enmod-remoteip": enable mod_remoteip
# in this throwaway container before the Apache configuration test, as the
# image's own start-up script does.
set -u
LC_ALL=C
export LC_ALL

php_source=$1
ext_dir=$2
web_server=$3
web_prepare=${4:-}
php_cli=/usr/bin/$php_source
php_fpm=/usr/sbin/php-fpm${php_source#php}

echo "@@ packages"
dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${Version}|${source:Package}\n' \
    | awk -F'|' '$1 ~ /^ii/ {sub(/ .*/, "", $4); print $2, $3, ($4 == "" ? $2 : $4)}' | sort

echo "@@ version"
"$php_cli" -v 2>&1 | head -n 1
"$php_fpm" -v 2>&1 | head -n 1

echo "@@ modules-cli"
"$php_cli" -m 2>&1

echo "@@ modules-fpm"
"$php_fpm" -m 2>&1

case "$web_prepare" in
    '') ;;
    a2enmod-remoteip) a2enmod -q remoteip >/dev/null 2>&1 || echo "a2enmod remoteip failed" >&2 ;;
    *) echo "unknown web prepare step: $web_prepare" >&2; exit 2 ;;
esac

echo "@@ config-tests"
fpm_test=$("$php_fpm" -t 2>&1)
echo "php-fpm exit=$?"
printf '%s\n' "$fpm_test" | sed 's/^\[[^]]*\] //'
case "$web_server" in
    nginx)
        web_test=$(nginx -t 2>&1)
        echo "nginx exit=$?"
        printf '%s\n' "$web_test"
        ;;
    apache2)
        web_test=$(apache2ctl -t 2>&1)
        echo "apache2 exit=$?"
        printf '%s\n' "$web_test"
        ;;
esac

echo "@@ web-modules"
case "$web_server" in
    apache2) apache2ctl -M 2>/dev/null | sort ;;
    nginx) nginx -V 2>&1 | sort ;;
esac

echo "@@ missing-libraries"
for binary in "$php_cli" "$php_fpm" /usr/lib/apache2/modules/libphp*.so "$ext_dir"/*.so; do
    [ -e "$binary" ] || continue
    ldd "$binary" 2>&1 | grep -E 'not found' | sed "s|^|$binary: |"
done

echo "@@ php-config-files"
php_conf_dir=/etc/php/${php_source#php}
find "$php_conf_dir" \( -type f -o -type l \) -print 2>/dev/null | sort | while IFS= read -r path; do
    if [ -L "$path" ]; then
        echo "link $(readlink "$path") $path"
    else
        echo "file $(sha256sum < "$path" | cut -c1-64) $path"
    fi
done

echo "@@ end"
