# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.


Vagrant.configure("2") do |config|

    config.vm.define "FHEM-Buienradar-Dev" do |machine|
        machine.vm.box = "debian/contrib-buster64"
        machine.vm.hostname = "FHEM-Buienradar-Dev"

        machine.vm.network "public_network", bridge: [
            "en0: WLAN (AirPort)",
            "en0: Ethernet"
        ]

        # mount for later created user "fhem" with later uid 999
        machine.vm.synced_folder ".", "/vagrant",
            owner: "998", group: "dialout"

        machine.vm.provider "virtualbox" do |v|
            # Customize the amount of memory on the VM:
            v.cpus = 2
            v.memory = 2048
        end

        machine.vm.provision "shell", path: "deployment.sh"
    end

    config.vm.define "FHEM-Buienradar-Integration" do |machine|
        machine.vm.box = "debian/contrib-buster64"
        machine.vm.hostname = "FHEM-Buienradar-Integration"

        machine.vm.network "public_network", bridge: [
            "en0: WLAN (AirPort)",
            "en0: Ethernet"
        ]

        # mount for later created user "fhem" with later uid 999
        machine.vm.synced_folder ".", "/vagrant",
            owner: "998", group: "dialout"

        machine.vm.provider "virtualbox" do |v|
            # Customize the amount of memory on the VM:
            v.cpus = 2
            v.memory = 2048
        end

        machine.vm.provision "shell" do |s|
            s.path = "deployment.sh"
            s.args = "integration"
        end
    end
end
