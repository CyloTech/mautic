#!/bin/bash
echo "**************************************************************"
echo "*                Installing MySQL Server                     *"
echo "**************************************************************"

echo "Installing MySQL"
apt update
apt install -y mysql-server

echo "Creating directories"
mkdir -p /home/appbox/mysql/run
mkdir -p /home/appbox/mysql/data
mkdir -p /home/appbox/logs/mysql
mkdir -p /home/appbox/config/mysql

echo "Creating log files"
touch /home/appbox/logs/mysql/error.log

echo "Moving sources"
mv /sources/mysqld.cnf /home/appbox/config/mysql/mysqld.cnf
chmod 600 /home/appbox/config/mysql/mysqld.cnf
chown -R appbox:appbox /home/appbox

echo "Starting MySQL for the first time"
mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --initialize-insecure

echo "Defining Variables"
DB_NAME=${DB_NAME:-""}
DB_USER=${DB_USER:-""}
DB_PASS=${DB_PASS:-""}

echo "Cycle MySQL service"
service mysql start
service mysql stop

echo "Create & secure runtime directories"
mkdir -p /var/run/mysqld
touch /var/run/mysqld/mysqld.sock
chown -R appbox:appbox /var/run/mysqld

echo "Start MySQL in safe mode"
/usr/bin/mysqld_safe --defaults-file=/home/appbox/config/mysql/mysqld.cnf &
sleep 10

echo "Setting up root password."
mysqladmin -u root password ${MYSQL_ROOT_PASSWORD}

echo "Enable remote root login."
# CREATE USER 'quser'@'localhost' IDENTIFIED BY 'qc123';
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%'; FLUSH PRIVILEGES;"

if [ -n "$DB_NAME" ]; then
    echo "Adding new DB $DB_NAME"
    mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE $DB_NAME"

    #We have setup a DB, so we can setup a cron to back it up.
    echo "+ Creating backup directory"
    mkdir -p /home/appbox/mysql/backup
    echo "0 0 * * * /usr/bin/mysqldump -uroot -p${MYSQL_ROOT_PASSWORD} ${DB_NAME} > /home/appbox/mysql/backup/${DB_NAME}_BACKUP.sql" > /sources/backupcron
    cat /sources/backupcron | crontab -
fi
if [ -n "$DB_USER" ]; then
    echo "Adding User $DB_USER"
    mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON DB_NAME TO 'DB_USER'@'localhost'; FLUSH PRIVILEGES;"

        mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '${DB_PASS}';"
    mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "GRANT ALL PRIVILEGES ON DB_NAME TO 'DB_USER'@'%'; FLUSH PRIVILEGES;"
fi
if [ -n "$DB_NAME" ]; then
    mysql --user=root --password=${MYSQL_ROOT_PASSWORD} -e "select user, host FROM mysql.user;"
fi


# Setup mysql Daemon
echo "Setting up MySQL Daemon"
mkdir -p /etc/service/mysql
cat << EOF >> /etc/service/mysql/run
#!/bin/sh
exec /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock
EOF
chmod +x /etc/service/mysql/run

echo "Finished installing MySQL"