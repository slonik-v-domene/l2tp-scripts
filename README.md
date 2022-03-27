# l2tp-scripts
This script is useful for creating L2TP through p2p VPN such as Wireguard.

First of all create configuration file in /etc/l2tp directory with name of bridge you want to use with.

Format of this file is pretty simple:

    [Bridge]
    Address  = 192.168.1.1/24

    [Local]
    Address  = 192.168.250.1

    [Remote]
    Address  = 192.168.250.10
    Id       = 10
    Attempts = 5

    [Remote]
    Address  = 192.168.250.20
    Id       = 20
    Attempts = 10

Where:
- Bridge/Address is ip-address of bridge infterface; if not set it will be used previous confugured address
- Local/Address is ip-address of local link of p2p VPN interface
- Remote/Address is ip-address of remote link of p2p VPN interface
- Remote/Id is L2TP both session and tunned id
- Remote/Attempts is number of connection attempts at startup; useful for poor internet connections

Make sure you have proper permissions for files /etc/l2tp/br0.sh (0600) and /etc/l2tp/l2tp.sh (0700)

Usage:
- systemctl enable l2tp@br0.service
- systemctl start l2tp@br0.service
- systemctl stop l2tp@br0.service
or
- /etc/l2tp/l2tp.sh up br0
- /etc/l2tp/l2tp.sh down br0

