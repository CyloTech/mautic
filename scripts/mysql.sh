#!/bin/bash
# Installs and secures the bundled MySQL server. The base image's
# /etc/my_init.d/20_installer.sh runs this once per container, so it runs on a
# fresh install and again whenever an existing install is re-created (update,
# migration). /home/appbox/config, /home/appbox/mysql and
# /home/appbox/public_html are persistent.
#
# The database password is never taken from the image. A new install gets a
# random root password; an existing install keeps the one in Mautic's
# config/local.php. Either way it is kept in $mysql_client_config (mode 0600)
# for the scripts and the backup job, and it is never put on a command line.
echo "**************************************************************"
echo "*                Installing MySQL Server                     *"
echo "**************************************************************"

mysql_config=/home/appbox/config/mysql/mysqld.cnf
mysql_client_config=/home/appbox/config/mysql/client.cnf
mysql_socket=/run/mysqld/mysqld.sock
mysql_datadir=/home/appbox/mysql/data

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "Installing MySQL"
apt update
apt install -y mysql-server

echo "Creating directories"
mkdir -p /home/appbox/mysql/run
mkdir -p "$mysql_datadir"
mkdir -p /home/appbox/logs/mysql
mkdir -p /home/appbox/config/mysql

echo "Creating log files"
touch /home/appbox/logs/mysql/error.log

echo "Moving sources"
mv /sources/mysqld.cnf "$mysql_config"
chmod 600 "$mysql_config"
chown -R appbox:appbox /home/appbox

if [ ! -d "$mysql_datadir/mysql" ]; then
    echo "Initialising the MySQL data directory"
    mysqld --defaults-file="$mysql_config" --initialize-insecure \
        || fail "could not initialise the MySQL data directory"
fi

echo "Cycle MySQL service"
service mysql start
service mysql stop

echo "Create & secure runtime directories"
mkdir -p /var/run/mysqld
touch /var/run/mysqld/mysqld.sock
chown -R appbox:appbox /var/run/mysqld

echo "Start MySQL in safe mode"
/usr/bin/mysqld_safe --defaults-file="$mysql_config" &
sleep 10
for _ in $(seq 1 150); do
    mysqladmin --no-defaults --socket="$mysql_socket" ping >/dev/null 2>&1 && break
    sleep 2
done

client_config_works() {
    [ -s "$1" ] && mysql --defaults-file="$1" -e 'SELECT 1' </dev/null >/dev/null 2>&1
}

root_accepts_no_password() {
    mysql --no-defaults --protocol=socket --socket="$mysql_socket" --user=root --skip-password \
        -e 'SELECT 1' </dev/null >/dev/null 2>&1
}

# Writes the client option file from $client_user and $client_password using
# shell builtins only, so the password does not appear in any process list.
write_client_config() {
    local target=$1
    rm -f "$target"
    (
        umask 077
        printf '[client]\nuser="%s"\npassword="%s"\nsocket=%s\n' \
            "$client_user" "$client_password" "$mysql_socket" > "$target"
    ) || return 1
    chmod 600 "$target"
}

mysql_admin_ready=false
pending_client_config="$mysql_client_config.new"
rm -f "$pending_client_config"

if client_config_works "$mysql_client_config"; then
    echo "Using the stored MySQL credentials"
    mysql_admin_ready=true
elif root_accepts_no_password; then
    if [ -e /home/appbox/public_html/mautic_installed ]; then
        fail "MySQL root has no password on an installed Mautic; refusing to continue"
    fi
    echo "Setting a random MySQL root password for this install"
    client_user=root
    client_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    case "$client_password" in
        ????????????????????????????????) ;;
        *) fail "could not generate a MySQL root password" ;;
    esac
    write_client_config "$pending_client_config" || fail "could not store the MySQL root password"
    printf "ALTER USER 'root'@'localhost' IDENTIFIED BY '%s';\n" "$client_password" \
        | mysql --no-defaults --protocol=socket --socket="$mysql_socket" --user=root --skip-password \
        || fail "could not set the MySQL root password"
    client_config_works "$pending_client_config" || fail "the new MySQL root password does not work"
    root_accepts_no_password && fail "MySQL root still accepts an empty password"
    mv -f "$pending_client_config" "$mysql_client_config" || fail "could not store the MySQL root password"
    mysql_admin_ready=true
else
    # An existing install: keep its password and read it from Mautic's config.
    echo "Reading the MySQL credentials from Mautic's configuration"
    mautic_local_config=
    for candidate in /home/appbox/public_html/config/local.php /home/appbox/public_html/app/config/local.php; do
        if [ -f "$candidate" ]; then
            mautic_local_config=$candidate
            break
        fi
    done
    client_credentials=
    if [ -n "$mautic_local_config" ]; then
        # PHP prints start-up warnings on stdout in this image; keep them off
        # it and take only what follows the marker.
        client_credentials=$(runuser -u appbox -- php -d display_errors=stderr -d display_startup_errors=0 -r '
            $parameters = [];
            include $argv[1];
            $user = $parameters["db_user"] ?? "";
            $password = $parameters["db_password"] ?? "";
            if (!is_string($user) || !is_string($password) || $user === "" || $password === ""
                || preg_match("/[\\x00-\\x1f\\x7f\"\\\\]/", $user . $password)) {
                exit(1);
            }
            echo "APPBOX-DB-LOGIN\n", $user, "\n", $password;
        ' -- "$mautic_local_config" 2>/dev/null) || client_credentials=
        case "$client_credentials" in
            *APPBOX-DB-LOGIN$'\n'*$'\n'*) client_credentials=${client_credentials##*APPBOX-DB-LOGIN$'\n'} ;;
            *) client_credentials= ;;
        esac
    fi
    if [ -n "$client_credentials" ]; then
        client_user=${client_credentials%%$'\n'*}
        client_password=${client_credentials#*$'\n'}
        if write_client_config "$pending_client_config" && client_config_works "$pending_client_config"; then
            mv -f "$pending_client_config" "$mysql_client_config" && mysql_admin_ready=true
        fi
    fi
    unset client_credentials
    rm -f "$pending_client_config"
    if [ "$mysql_admin_ready" != true ]; then
        echo "WARNING: could not use the database login in Mautic's configuration; MySQL accounts left unchanged" >&2
    fi
fi
unset client_password

if [ "$mysql_admin_ready" = true ]; then
    echo "Removing remote root login"
    mysql --defaults-file="$mysql_client_config" -e "DROP USER IF EXISTS 'root'@'%';" </dev/null \
        || echo "WARNING: could not remove remote root login" >&2

    if [ -n "$DB_NAME" ]; then
        case "$DB_NAME" in
            *[!A-Za-z0-9_]*) fail "invalid DB_NAME" ;;
        esac
        echo "Ensuring database $DB_NAME exists"
        mysql --defaults-file="$mysql_client_config" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" </dev/null

        #We have setup a DB, so we can setup a cron to back it up.
        echo "+ Creating backup directory"
        mkdir -p /home/appbox/mysql/backup
        echo "0 0 * * * /usr/bin/mysqldump --defaults-file=$mysql_client_config ${DB_NAME} > /home/appbox/mysql/backup/${DB_NAME}_BACKUP.sql" | crontab -
        mysql --defaults-file="$mysql_client_config" -e "select user, host FROM mysql.user;" </dev/null
    fi
fi


# Setup mysql Daemon
echo "Setting up MySQL Daemon"
mkdir -p /etc/service/mysql
cat << EOF > /etc/service/mysql/run
#!/bin/sh
exec /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock --bind-address=127.0.0.1 --loose-mysqlx-bind-address=127.0.0.1
EOF
chmod +x /etc/service/mysql/run

echo "Finished installing MySQL"
