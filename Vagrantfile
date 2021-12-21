# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box_check_update = false
  config.vm.provider 'virtualbox' do |vb|
    vb.customize [ "guestproperty", "set", :id, "/VirtualBox/GuestAdd/VBoxService/--timesync-set-threshold", 1000 ]
  end
  config.vm.synced_folder ".", "/vagrant", type: "rsync"
  $num_instances = 3
  (1..$num_instances).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.box = "ubuntu/focal64"
      node.vm.hostname = "node#{i}"
      privateIP = "192.168.56.#{i+100}"
      node.vm.network "private_network", ip: privateIP
      node.vm.provider "virtualbox" do |vb|
        vb.memory = "3072"
        vb.cpus = 1
        vb.name = "node#{i}"
      end
      vagrantRoot = File.dirname(__FILE__)
      node.vm.provision "shell" do |s|
        publicKey = File.readlines("#{vagrantRoot}/ssh/id_rsa.pub").first.strip
        s.inline = <<-SHELL
        echo #{publicKey} >> /home/vagrant/.ssh/authorized_keys
        echo #{publicKey} >> /root/.ssh/authorized_keys
        SHELL
      end
      node.vm.provision "file", source: "#{vagrantRoot}/ssh/id_rsa", destination: "/home/vagrant/.ssh/id_rsa"
      node.vm.provision "shell", path: "install.bash"
    end
  end
end
