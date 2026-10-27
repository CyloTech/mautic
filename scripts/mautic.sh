#!/bin/bash
set -x

echo "Creating directories"
mkdir -p /home/appbox/logs/apache
mkdir -p /home/appbox/config/php-fpm/pool.d
mkdir -p /home/appbox/public_html
mkdir -p /run/php

	cat <<EOF > /etc/php/8.3/fpm/php.ini
date.timezone = "${PHP_INI_DATE_TIMEZONE}"
always_populate_raw_post_data = -1
memory_limit = ${PHP_MEMORY_LIMIT}
file_uploads = On
upload_max_filesize = ${PHP_MAX_UPLOAD}
post_max_size = ${PHP_MAX_UPLOAD}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
variables_order = "EGPCS"
zend.assertions = -1
EOF

cat <<EOF > /etc/php/8.3/cli/php.ini
date.timezone = "${PHP_INI_DATE_TIMEZONE}"
always_populate_raw_post_data = -1
memory_limit = ${PHP_MEMORY_LIMIT}
file_uploads = On
upload_max_filesize = ${PHP_MAX_UPLOAD}
post_max_size = ${PHP_MAX_UPLOAD}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
variables_order = "EGPCS"
zend.assertions = -1
EOF

if [ -n "$MYSQL_PORT_3306_TCP" ]; then
        if [ -z "$MAUTIC_DB_HOST" ]; then
                export MAUTIC_DB_HOST='mysql'
                if [ "$MAUTIC_DB_USER" = 'root' ] && [ -z "$MAUTIC_DB_PASSWORD" ]; then
                        export MAUTIC_DB_PASSWORD="$MYSQL_ENV_MYSQL_ROOT_PASSWORD"
                fi
        else
                echo >&2 "warning: both MAUTIC_DB_HOST and MYSQL_PORT_3306_TCP found"
                echo >&2 "  Connecting to MAUTIC_DB_HOST ($MAUTIC_DB_HOST)"
                echo >&2 "  instead of the linked mysql container"
        fi
fi



if [ -z "$MAUTIC_DB_HOST" ]; then
        echo >&2 "error: missing MAUTIC_DB_HOST and MYSQL_PORT_3306_TCP environment variables"
        echo >&2 "  Did you forget to --link some_mysql_container:mysql or set an external db"
        echo >&2 "  with -e MAUTIC_DB_HOST=hostname:port?"
        exit 1
fi


if [ -z "$MAUTIC_DB_PASSWORD" ]; then
        echo >&2 "error: missing required MAUTIC_DB_PASSWORD environment variable"
        echo >&2 "  Did you forget to -e MAUTIC_DB_PASSWORD=... ?"
        echo >&2
        echo >&2 "  (Also of interest might be MAUTIC_DB_USER and MAUTIC_DB_NAME.)"
        exit 1
fi

#ENABLES HUBSPOT CRON
if [ -n "$MAUTIC_CRON_HUBSPOT" ]; then
        echo >&2 "CRON: Activating Hubspot"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:fetchleads --integration=Hubspot >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
        echo "15,45 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:pushactivity --integration=Hubspot >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

#ENABLES SALESFORCE CRON
if [ -n "$MAUTIC_CRON_SALESFORCE" ]; then
        echo >&2 "CRON: Activating Salesforce"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:fetchleads --integration=Salesforce >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
        echo "12,42 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:pushactivity --integration=Salesforce >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
        echo "14,44 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:pushleadactivity --integration=Salesforce >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
        echo "16,46 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:synccontacts --integration=Salesforce >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

#ENABLES SUGARCRM CRON
if [ -n "$MAUTIC_CRON_SUGARCRM" ]; then
        echo >&2 "CRON: Activating SugarCRM"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:fetchleads --fetch-all --integration=Sugarcrm >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

#ENABLES PIPEDRIVE CRON
if [ -n "$MAUTIC_CRON_PIPEDRIVE" ]; then
        echo >&2 "CRON: Activating Pipedrive"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:pipedrive:fetch >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
        echo "15,45 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:pipedrive:push >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

#ENABLES ZOHO CRON
if [ -n "$MAUTIC_CRON_ZOHO" ]; then
        echo >&2 "CRON: Activating ZohoCRM"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:fetchleads --integration=Zoho >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

#ENABLES DYNAMICS CRON
if [ -n "$MAUTIC_CRON_DYNAMICS" ]; then
        echo >&2 "CRON: Activating DynamicsCRM"
        echo "10,40 * * * *     appbox   php /home/appbox/public_html/bin/console mautic:integration:fetchleads -i Dynamics >> /var/log/cron.pipe 2>&1" >> /etc/cron.d/appbox
fi

if ! [ -e mautic_installed ]; then
        echo >&2 "Upgrade/Installing mautic to $(pwd) - copying now..."

        if [ "$(ls -A)" ]; then
                echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
                ( set -x; ls -A; sleep 10 )
        fi

        tar cf - --one-file-system -C /usr/src/mautic . | tar xf -
        echo >&2 "Complete! Mautic has been successfully copied to $(pwd)"
else
        if [ ! -f /etc/installer_completed_mautic ]; then
                echo "Upgrading Mautic!"
                # Don't delete public_html because it contains user data (configs)
                su -c "php bin/console mautic:update:find --no-interaction" -s /bin/bash appbox
                su -c "php bin/console mautic:update:apply --force" -s /bin/bash appbox
                su -c "php bin/console mautic:update:apply --finish" -s /bin/bash appbox
                su -c "php bin/console doctrine:migration:migrate -n" -s /bin/bash appbox
                su -c "php bin/console cache:clear" -s /bin/bash appbox
        fi
fi

# if ! [ -e app/config/local.php ]; then
#         # Ensure the MySQL Database is created
#         php /makedb.php "$MAUTIC_DB_HOST" "$MAUTIC_DB_USER" "$MAUTIC_DB_PASSWORD" "$MAUTIC_DB_NAME"
# fi

echo >&2 "========================================================================"
echo >&2
echo >&2 "This server is now configured to run Mautic!"
echo >&2 "The following information will be prefilled into the installer (keep password field empty):"
echo >&2 "Host Name: $MAUTIC_DB_HOST"
echo >&2 "Database Name: $MAUTIC_DB_NAME"
echo >&2 "Database Username: $MAUTIC_DB_USER"
echo >&2 "Database Password: $MAUTIC_DB_PASSWORD"

# Write the database connection to the config so the installer prefills it
if [ ! -f /home/appbox/public_html/config/local.php ]; then

	su -s /bin/bash appbox -c 'touch /home/appbox/public_html/config/local.php'

	cat <<'EOF' > /home/appbox/public_html/config/local.php
<?php
$parameters = array(
	'db_driver' => 'pdo_mysql',
	'db_host' => getenv('MAUTIC_DB_HOST'),
	'db_port' => getenv('MAUTIC_DB_PORT'),
	'db_name' => getenv('MAUTIC_DB_NAME'),
	'db_user' => getenv('MAUTIC_DB_USER'),
	'db_password' => getenv('MAUTIC_DB_PASSWORD'),
	'db_table_prefix' => null,
	'db_backup_tables' => 1,
	'db_backup_prefix' => 'bak_',
);
EOF
fi

echo >&2
echo >&2 "========================================================================"


# echo "Moving sources"
# mv /sources/php-fpm.conf /home/appbox/config/php-fpm/php-fpm.conf
# mv /sources/www.conf /home/appbox/config/php-fpm/pool.d/www.conf

chown -R appbox:appbox /home/appbox

if ! [ -e mautic_installed ]; then
        /usr/sbin/php-fpm8.3 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        /usr/local/bin/apache2-foreground &

        echo "Waiting for Mautic to come up"
        until [[ $(curl -i -L http://localhost/installer | grep 'DOCTYPE html') ]]; do
                printf '.'
                sleep 1
        done

        rm -rf /home/appbox/public_html/var/cache/*

        # Warm up the cache
        su -c "php bin/console cache:warmup --env=prod" -s /bin/bash appbox

        su -c "php bin/console mautic:install -n -f --db_driver=pdo_mysql --db_host=$MAUTIC_DB_HOST --db_port=3306 --db_name=$MAUTIC_DB_NAME --db_user=$MAUTIC_DB_USER --db_password=$MAUTIC_DB_PASSWORD --admin_firstname=$FIRSTNAME --admin_lastname=$LASTNAME --admin_username=$USERNAME --admin_email=$EMAIL --admin_password=$PASSWORD https://$HOSTNAME 0" -s /bin/bash appbox
fi

echo "Killing MySQL"
pkill -9 mysql

echo "Killing Apache"
pkill -9 apache2

echo "Killing PHP"
pkill -9 php

touch mautic_installed
touch /etc/installer_completed_mautic


# Setup apache Daemon
echo "Setting up apache daemon"
mkdir -p /etc/service/apache
cat << EOF > /etc/service/apache/run
#!/bin/sh
exec /usr/local/bin/apache2-foreground
EOF
chmod +x /etc/service/apache/run

# Setup Daemon to send emails immediately
echo "Setting up workers"
mkdir -p /etc/service/workers
cat << 'EOF' > /etc/service/workers/run
#!/bin/bash
until php -r 'file_exists("/home/appbox/public_html/config/local.php") ? include("/home/appbox/public_html/config/local.php") : exit(1); exit(isset($parameters["site_url"]) ? 0 : 1);'; do
	echo "Mautic not installed, waiting to start workers"
	sleep 5
done

exec su -s /bin/bash -c '[[ "\$(ls -A /home/appbox/public_html/app/cache/ip_data 2>/dev/null)" ]] || php /home/appbox/public_html/bin/console mautic:iplookup:download; while true; do php /home/appbox/public_html/bin/console messenger:consume email >/dev/null; php /home/appbox/public_html/bin/console messenger:consume hit >/dev/null; php /home/appbox/public_html/bin/console messenger:consume failed >/dev/null; php /home/appbox/public_html/bin/console mautic:segments:update >/dev/null; php /home/appbox/public_html/bin/console mautic:campaigns:update >/dev/null; php /home/appbox/public_html/bin/console mautic:campaigns:trigger >/dev/null; sleep 1; done' appbox
EOF
chmod +x /etc/service/workers/run