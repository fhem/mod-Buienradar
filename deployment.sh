#! /usr/bin/env bash

#   +----------------------------------------------------------------------------
#   |
#   |   helper functions
#   |
#   +----------------------------------------------------------------------------

# prepare environment
#   See http://www.davidpashley.com/articles/writing-robust-shell-scripts/
set -o nounset
set -o errexit

# catch exits and clean up if any is catched
trap "" INT TERM EXIT


case "$1" in
    deployment)
        LIBRARY_DIR="/vagrant/deployment/"
    ;;
    integration)
        LIBRARY_DIR="/vagrant/integration/"
    ;;
    default)
        echo "$1 is not a valid environment: deployment or integration"
    ;;
esac

LOCALE="de_DE.utf8"

function install_puppet {
    puppet_source="https://apt.puppetlabs.com/puppetlabs-release-pc1-jessie.deb"
    puppet_target="/tmp/puppet.deb"

    echo '##########################'
    echo '##########################'
    echo Downloading puppet from $puppet_source

    wget -q -O $puppet_target $puppet_source

    echo '##########################'
    echo '##########################'
    echo Installing puppet from $puppet_target

    dpkg -i $puppet_target
    $APT_BIN -q update
    $APT_BIN install -y puppet-agent

}

function setup_pm {
    echo '##########################'
    echo '##########################'
    echo Installing apt

    apt-get --allow-releaseinfo-change update

    command -v apt || {
        apt-get install -y apt
    }

    export APT_BIN="apt"
}

function upgrade_system {
    echo '##########################'
    echo '##########################'
    echo Upgrading system

    $APT_BIN -q update
    $APT_BIN -y upgrade
}

function install_tools {
    echo '##########################'
    echo '##########################'
    echo Installing base tools

    $APT_BIN install -y htop tree vim git dnsutils telnet cpanminus build-essential curl wget
}

function set_time {
    echo '##########################'
    echo '##########################'
    echo "Setup time & time zone"
    
    # set timezone
    echo "Europe/Berlin" > /etc/timezone
    ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata
    
    # update time via ntp
    # $APT_BIN install ntpdate
    # ntpdate europe.pool.ntp.org

    # activate ntp and set timezone in systemd-mode
    timedatectl set-ntp true
    timedatectl set-timezone Europe/Berlin
    timedatectl
}

function set_locale {

    locale="$LOCALE"

    echo '##########################'
    echo '##########################'
    echo Setup locale   
    
    echo  "${locale} UTF-8" > /etc/locale.gen
    sudo locale-gen ${locale}
    
    export LC_ALL="${locale}"
    #echo Would export LC_ALL="${locale}"

    export LANG="${locale}"
    #echo Would export LANG="${locale}"

    export LANGUAGE="${locale}"
    #echo Would export LANGUAGE="${locale}"
        
    # update locale
    echo "LANG=${locale}" > /etc/default/locale
    echo "/etc/default/locale:";
    cat /etc/default/locale

    sudo update-locale LANG="${locale}"
    sudo update-locale LANGUAGE="${locale}"
    sudo update-locale LC_ALL="${locale}"

    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales
    
    # disable sshd's annoying LC_* copy
    sed -e '/AcceptEnv/ s/^#*/#/' -i /etc/ssh/sshd_config
}

function show_ip {
    ip address
}

#   +----------------------------------------------------------------------------
#   |
#   |   main
#   |
#   +----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

#sudo -n su
setup_pm
upgrade_system
install_tools
set_time
set_locale

# install application specific library files
echo "Try to install files in library at ${LIBRARY_DIR}"
test -d "${LIBRARY_DIR}" && {
    echo "Found a library folder"
    for lib_file in $(find ${LIBRARY_DIR} -iname '*.sh');
    do
        echo "Executing file ${lib_file}"
        bash ${lib_file};
    done
}

show_ip