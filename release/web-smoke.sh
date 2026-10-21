#!/bin/sh
# Usage (inside the image, as root, no network): web-smoke.sh <php source package> <nginx|apache2>
#
# Starts the image's own web server and the PHP SAPI its configuration sends
# .php requests to, with one extra test site on 127.0.0.1:8090, then checks
# that a PHP page is served through that SAPI at the CLI's PHP version and
# that a multipart upload fills $_POST and $_FILES. It only changes the
# throwaway container it runs in.
#
# - nginx: php-fpm behind fastcgi_pass, as the image's site does.
# - apache2: if the enabled Apache configuration hands .php files to php-fpm
#   (SetHandler "proxy:unix:<socket>|fcgi://..."), php-fpm is started on that
#   socket and must answer; otherwise mod_php must answer.
# php-fpm runs the package's php.ini and extension set with a throwaway pool
# on that socket, so the test does not depend on pools that the image's
# start-up scripts write.
set -eu

php_source=$1
web_server=$2
php_version=${php_source#php}
case "$php_version" in [0-9].[0-9]) ;; *) echo "bad php source package: $php_source" >&2; exit 2 ;; esac
php_fpm=/usr/sbin/php-fpm$php_version

site=/tmp/cylo-gate-site
mkdir -p "$site"
cat > "$site/page.php" <<'PHP'
<?php
echo PHP_SAPI, ' ', PHP_VERSION;
PHP
cat > "$site/upload.php" <<'PHP'
<?php
echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
printf 'hello' > /tmp/cylo-gate-upload.txt
chmod 755 "$site"
chmod 644 "$site/page.php" "$site/upload.php" /tmp/cylo-gate-upload.txt

# Start php-fpm with a throwaway pool listening on socket $1.
start_fpm_on() {
    fpm_socket=$1
    mkdir -p "$(dirname "$fpm_socket")"
    cat > /tmp/cylo-gate-fpm.conf <<EOF
[global]
pid = /tmp/cylo-gate-fpm.pid
error_log = /tmp/cylo-gate-fpm.log
daemonize = yes
[cylo-gate]
user = www-data
group = www-data
listen = $fpm_socket
listen.mode = 0666
pm = static
pm.max_children = 2
EOF
    "$php_fpm" --fpm-config /tmp/cylo-gate-fpm.conf
    for attempt in $(seq 1 60); do
        [ -S "$fpm_socket" ] && return 0
        sleep 0.5
    done
    echo "php-fpm did not create $fpm_socket" >&2
    cat /tmp/cylo-gate-fpm.log >&2 || true
    exit 1
}

case "$web_server" in
    apache2)
        # The start-up script enables mod_remoteip, which the default site needs.
        a2enmod -q remoteip >/dev/null
        apache_log_dir=$(set +u; . /etc/apache2/envvars >/dev/null 2>&1; printf '%s' "${APACHE_LOG_DIR:-}")
        [ -z "$apache_log_dir" ] || mkdir -p "$apache_log_dir"
        proxy_socket=$(cat /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf /etc/apache2/mods-enabled/*.conf 2>/dev/null \
            | grep -v '^[[:space:]]*#' | grep -oE 'proxy:unix:[^|"]+' | sed 's/^proxy:unix://' | sort -u)
        case "$proxy_socket" in
            '') expected_sapi=apache2handler ;;
            *[!A-Za-z0-9._/-]*) echo "unexpected php-fpm handlers in the Apache configuration: $proxy_socket" >&2; exit 1 ;;
            *)
                expected_sapi=fpm-fcgi
                echo "Apache hands .php files to php-fpm on $proxy_socket"
                start_fpm_on "$proxy_socket"
                ;;
        esac
        cat > /etc/apache2/sites-enabled/zz-cylo-gate.conf <<EOF
Listen 127.0.0.1:8090
<VirtualHost 127.0.0.1:8090>
    DocumentRoot $site
    <Directory $site>
        Require all granted
    </Directory>
</VirtualHost>
EOF
        apache2ctl -t
        apache2ctl start
        ;;
    nginx)
        expected_sapi=fpm-fcgi
        fpm_socket=/run/php/cylo-gate-fpm.sock
        start_fpm_on "$fpm_socket"
        cat > /etc/nginx/conf.d/zz-cylo-gate.conf <<EOF
server {
    listen 127.0.0.1:8090;
    root $site;
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$fpm_socket;
    }
}
EOF
        nginx -t
        nginx
        ;;
    *) echo "unknown web server: $web_server" >&2; exit 2 ;;
esac

body=/tmp/cylo-gate-body
http_get() {
    curl -sS --max-time 30 -o "$body" -w '%{http_code}' "$@"
}

for attempt in $(seq 1 60); do
    curl -s --max-time 2 -o /dev/null http://127.0.0.1:8090/ && break
    sleep 0.5
done

status=$(http_get http://127.0.0.1:8090/page.php)
page=$(cat "$body")
cli_php_version=$("/usr/bin/$php_source" -r 'echo PHP_VERSION;')
if [ "$status" != 200 ] || [ "$page" != "$expected_sapi $cli_php_version" ]; then
    echo "PHP page through $web_server returned HTTP $status '$page', expected 200 '$expected_sapi $cli_php_version'" >&2
    exit 1
fi
echo "PHP page served by $web_server: $page"

status=$(http_get -F a=b -F f=@/tmp/cylo-gate-upload.txt http://127.0.0.1:8090/upload.php)
upload=$(cat "$body")
if [ "$status" != 200 ] || [ "$upload" != "1:5:b" ]; then
    echo "multipart upload through $web_server returned HTTP $status '$upload', expected 200 '1:5:b'" >&2
    exit 1
fi
echo "multipart upload through $web_server ok"
