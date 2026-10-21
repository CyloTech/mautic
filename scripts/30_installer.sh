#!/bin/bash
set -x

echo "Cleaning up locks"
rm /run/mysqld/mysqld.sock.lock || true
rm /var/run/crond.pid || true

cat << EOF > /etc/service/phpfpm/run
#!/bin/sh
exec /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf
EOF

if [ ! -f /etc/installer_completed_mautic ]; then

echo "**************************************************************"
echo "*                                                            *"
echo "*                 Cylo Base Installer 1.0                    *"
echo "*                     Installing Apps:                       *"
echo "*                                                            *"
echo "**************************************************************"
echo "Mysql"
echo "Mautic"
echo " "
echo "**************************************************************"
echo " "


    rm -rf /etc/service/nginx
    
    echo "Enabling mod_remoteip"
    a2enmod remoteip

    echo "Installing Mautic"
    /bin/bash /scripts/mautic.sh

    # Clean Up
    echo "Cleaning up"
    rm -fr /sources

    apt autoremove -y
    apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "                                   .''.       "
echo "       .''.      .        *''*    :_\/_:     . "
echo "      :_\/_:   _\(/_  .:.*_\/_*   : /\ :  .'.:.'."
echo "  .''.: /\ :   ./)\   ':'* /\ * :  '..'.  -=:o:=-"
echo " :_\/_:'.:::.    ' *''*    * '.\'/.' _\(/_'.':'.'"
echo " : /\ : :::::     *_\/_*     -= o =-  /)\    '  *"
echo "  '..'  ':::'     * /\ *     .'/.\'.   '"
echo "      *            *..*         :"

    echo "Finishing Install"
    # Finish Install
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
        do
        sleep 5
    done
    touch /etc/installer_completed_mautic

fi

# Internal upgrades can break mautic so we ensure the following line is in index
if ! cat /home/appbox/public_html/index.php | grep -q "\$_SERVER\['HTTPS'\]"; then
echo "Adding HTTPs on to index.php"
sed -i "/<?php/a \$_SERVER['HTTPS'] = 'on';" /home/appbox/public_html/index.php
fi