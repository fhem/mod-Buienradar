#!/usr/bin/env bash
#
#   Add a http server to mock json data
#

function install_webserver {
    apt install apache2
}

function redirect_dns {
    echo "127.0.0.1 cdn-secure.buienalarm.nl" |tee -a /etc/hosts
}

function create_mockdata {
    mkdir -p /var/www/html/api/3.4
    rm /var/www/html/api/3.4/forecast.php
    ln -s /vagrant/deployment/mock-data/forecast.json /var/www/html/api/3.4/forecast.php
}

function install_config {
    rm /etc/apache2/sites-available/mock-data.conf
    ln -s /vagrant/deployment/mock-data/mock-data.conf /etc/apache2/sites-available/
    a2ensite mock-data
}

install_webserver
redirect_dns
create_mockdata
install_config

systemctl restart apache2
curl -Is 'https://cdn-secure.buienalarm.nl/api/3.4/forecast.php?lat=51.9293504&lon=8.377413199999978&region=nl&unit=mm/u' --cacert /vagrant/deployment/mock-data/buienradar.crt