#!/bin/sh
# Usage (inside the image, as root, no network): web-smoke.sh <php source package> <nginx|apache2>
#
# Starts the image's own web server and PHP SAPI (mod_php for apache2,
# php-fpm behind nginx) with one extra test site on 127.0.0.1:8090, then
# checks that a PHP page is served through that SAPI and that a multipart
# upload fills $_POST and $_FILES. It only changes the throwaway container
# it runs in.
set -eu

php_source=$1
web_server=$2
php_version=${php_source#php}
case "$php_version" in [0-9].[0-9]) ;; *) echo "bad php source package: $php_source" >&2; exit 2 ;; esac

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

case "$web_server" in
    apache2)
        expected_sapi=apache2handler
        # The start-up script enables mod_remoteip, which the default site needs.
        a2enmod -q remoteip >/dev/null
        apache_log_dir=$(set +u; . /etc/apache2/envvars >/dev/null 2>&1; printf '%s' "${APACHE_LOG_DIR:-}")
        [ -z "$apache_log_dir" ] || mkdir -p "$apache_log_dir"
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
        fpm_socket=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "/etc/php/$php_version/fpm/pool.d/www.conf" | head -n 1)
        case "$fpm_socket" in /*) ;; *) echo "php-fpm www pool does not listen on a socket: '$fpm_socket'" >&2; exit 1 ;; esac
        mkdir -p "$(dirname "$fpm_socket")"
        "/usr/sbin/php-fpm$php_version" --daemonize
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
