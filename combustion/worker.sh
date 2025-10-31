#!/bin/sh
# combustion: network
set -euxo pipefail

# Variables
NODE_HOSTNAME='micro3'
NODE_IP_ADDR='192.168.4.111'
USER=''
USER_PASSWORD=''
ROOT_PASSWORD=''
PUB_KEY=''
K3S_API_HOST=''
K3S_TOKEN=''
KEYMAP=''

# Redirect output to the console
exec > >(exec tee -a /dev/tty0) 2>&1

os_admin_settings () {
	# Keyboard lang 
	echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
	# Set Hostname
	echo "${NODE_HOSTNAME}" > /etc/hostname
	# Password (redo)
	echo "root:${ROOT_PASSWORD}" | chpasswd -e
	# Non-root sudo user
	mount /var && mount /home
	useradd -m ${USER} -s /bin/bash -g users
	echo "${USER}:${USER_PASSWORD}" | chpasswd -e
	echo "${USER} ALL=(ALL) ALL" >> /etc/sudoers.d/adminusers
	mkdir -pm700 "/home/${USER}/.ssh/"
	chown -R "${USER}:users" "/home/${USER}/.ssh/"
	echo "${PUB_KEY}" >> "/home/${USER}/.ssh/authorized_keys"
}

network_settings () {
	## NETWORK BLOCK
	umask 077 
	mkdir -p /etc/NetworkManager/system-connections/
	# Bridge connection
	cat >/etc/NetworkManager/system-connections/br0.nmconnection <<-EOF
	[connection]
	id=br0
	type=bridge
	autoconnect=true
	interface-name=br0

	[bridge]
	stp=false
	forward-delay=0

	[ipv4]
	method=manual
	address1=${NODE_IP_ADDR}/${NODE_MASK},${NODE_IP_GW}
	dns=${NODE_IP_GW}

	[ipv6]
	method=ignore
	EOF

	# Physical NIC as bridge slave
	cat >/etc/NetworkManager/system-connections/enp1s0-slave.nmconnection <<-EOF
	[connection]
	id=enp1s0-slave
	type=ethernet
	autoconnect=true
	interface-name=enp1s0
	master=br0
	slave-type=bridge
	EOF
	chmod 600 /etc/NetworkManager/system-connections/*.nmconnection
}

k3s_installer () {
	zypper --non-interactive install \
		k3s-install \
		open-iscsi # Longhorn Dependency

	cat >/etc/systemd/system/k3s-init.service <<-EOF 
	[Unit]
	Description=Run K3s installer
	Wants=network-online.target
	After=network.target network-online.target
	ConditionPathExists=/usr/bin/k3s-install
	ConditionPathExists=!/usr/local/bin/k3s

	[Service]
	Type=oneshot
	TimeoutStartSec=120
	Environment=K3S_URL=https://$K3S_API_HOST:6443
	Environment=K3S_TOKEN=$K3S_TOKEN
	Environment=K3S_KUBECONFIG_MODE=644
	ExecStart=/usr/bin/k3s-install
	ExecStart=systemctl enable --now k3s.service
	ExecStart=systemctl disable firstbootreboot.service
	ExecStart=rm /etc/systemd/system/firstbootreboot.service
	ExecStart=rm /etc/systemd/system/k3s-init.service
	ExecStart=systemctl disable k3s-init.service
	KillMode=process

	[Install]
	WantedBy=multi-user.target
	EOF
}

finalizers () {
	# A reboot is required to trigger SELinux relabeling.
	# This will also bring up the bridge interface
	cat >/etc/systemd/system/firstbootreboot.service <<-EOF
	[Unit]
	Description=First Boot Reboot
	After=multi-user.target
	ConditionPathExists=/etc/firstboot.reboot.required

	[Service]
	Type=oneshot
	ExecStart=rm /etc/firstboot.reboot.required
	ExecStart=systemctl enable k3s-init.service
	ExecStart=systemctl reboot

	[Install]
	WantedBy=multi-user.target
	EOF


	# Services
	touch /etc/firstboot.reboot.required
	systemctl enable sshd.service
	systemctl enable firstbootreboot.service 
	systemctl enable iscsid.service

	echo "Configured with combustion" > /etc/issue.d/combustion
}

os_admin_settings
network_settings
k3s_installer
finalizers

exec 1>&- 2>&-; wait;

