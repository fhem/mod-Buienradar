#!/usr/bin/env bash

test -z "$APT_BIN" && APT_BIN="apt"

function install_fhem {
    echo
    echo
    echo Installing FHEM
    
    sources="/etc/apt/sources.list.d/fhem.list"

    # add fhem sources and install
    wget -qO - http://debian.fhem.de/archive.key | apt-key add -
    echo "deb http://debian.fhem.de/nightly/ /" >> "${sources}"
    ${APT_BIN} update
    ${APT_BIN} install -y fhem

    # restore original
    rm "${sources}"
    ${APT_BIN} update
}

function install_cfg {
    rm -rf /opt/fhem/fhem.cfg
    ln -s /vagrant/deployment/fhem/fhem.cfg /opt/fhem/fhem.cfg
}

function install_modules {
    rm -rf /opt/fhem/FHEM/59_Buienradar.pm
    ln -s /vagrant/FHEM/59_Buienradar.pm /opt/fhem/FHEM/59_Buienradar.pm
}

function update_commandref {
    cwd=$(pwd)
    cd /opt/fhem
    perl contrib/commandref_join.pl
    cd $cwd
}

function add_sudoers {
    sudoers_file="/etc/sudoers.d/fhem"

    rm -f "${sudoers_file}"
    sudo echo "fhem ALL=(ALL) NOPASSWD:SETENV: /usr/bin/cpanm *" >> "${sudoers_file}"
    chmod 0440 "${sudoers_file}"
}

function perl_modules {
    cpanm install App::cpanoutdated Perl::PrereqScanner::NotQuiteLite IO::Socket::INET6 Socket6 Cpanel::JSON::XS JSON::MaybeXS
}

perl_modules
install_fhem
install_cfg
install_modules
perl_modules
add_sudoers
update_commandref


service fhem restart