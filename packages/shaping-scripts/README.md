This is a small script that sets up traffic shaping on a Linux router box,
using the `tc` command from `iproute2`.

In the current setup, outgoing traffic is classified into the following
classes, each having specific shaping rules:

* LAN: No shaping
* WAN: Capped at the maximum upload bandwith (85kbps)
  * Priority 1: Highest priority (10kbps reserved)
    * DNS
    * Small TCP control packets (e.g. `SYN`, `ACK`, `RST`)
  * Priority 2: High priority (70 kbps reserved)
    * HTTP(S)
    * SSH
    * [Subsonic](http://subsonic.org) (a self-hosted music streaming server)
    * Email
  * Priority 3: Normal priority (default, 5kbps reserved)
  * Priority 4: Low priority (5kbps reserved)
    * Bittorrent traffic

# Installation

## Manual setup

The main traffic shaping script is `shaper.sh`:

    shaper.sh enp3s0 up    # Enables traffic shaping
    shaper.sh enp3s0 down  # Disables traffic shaping

## Automatic setup

Enabling traffic shaping automatically requires NetworkManager Dispatcher to
work. Just type `make install` to install everything, and make sure that the
dispatcher service is running.

## Zabbix monitoring

Included are 3 files for monitoring traffic statistics with
[Zabbix](http://zabbix.com) :

* `tstat` collects class statistics and performs class discovery
* `zabbix_userparams.conf` adds the required keys to a Zabbix Agent
* `zabbix_template.xml` adds a _Traffic shaping_ template that automatically
  adds items for every running traffic class defined in `tc_cls` using the
  `tstat` command.

The Zabbix template configures items for each non-root, leaf class. These can
then be used, e.g. for displaying stacked graphs like this one:

![Traffic shaping graph in Zabbix](.images/zabbix_shaping_graph.png?raw=true)

# Configuration

Your network characteristics will most probably not match mine (roughly 800kbps
down, 85kbps up). The most important thing to edit is your maximum upload
bandwith, defined in the `MAX_UPLOAD` variable.

If your local network is not `192.168.1.0/24`, you also need to replace the
`LOCALNET_IPV4` variable by your own ip/mask.

Additionally, you can edit the reserved rate for each priority class (`WAN1-4`)
later in the file. Keep in mind that each class can borrow from the others if
necessary; these rates represent the minimum reserved bandwith for each class:

    create_class $CLASS_WAN1 10kbps  ${CLASS_WAN}
    create_class $CLASS_WAN2 70kbps  ${CLASS_WAN}
    create_class $CLASS_WAN3 5kbps   ${CLASS_WAN}
    create_class $CLASS_WAN4 5kbps   ${CLASS_WAN}
