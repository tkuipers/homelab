# Seed Server Setup (Ubuntu 24.04)

This directory contains the configuration files for the server that will act as the "seed cluster" for the main Talos homelab. Its primary roles are to run the Sidero Metal controller and to provide DHCP/PXE services to the network.

## 1. Initial Server Setup

1.  Install Ubuntu Server 24.04 (64-bit).
2.  Boot the server and ensure it has network connectivity.
3.  **Set a static IP address:**
    -   Ubuntu Server uses `netplan` for network configuration. First, identify your network interface name:
        ```bash
        ip a
        ```
        Look for an interface like `enp1s0`, `eth0`, or similar.
    -   Create a new netplan configuration file. Configurations are in `/etc/netplan/` and are processed in lexical order. It's common to create a file like `01-netcfg.yaml`.
        ```bash
        sudo nano /etc/netplan/01-netcfg.yaml
        ```
    -   Add the following content, replacing `eth0` with your actual interface name:
        ```yaml
        network:
          version: 2
          renderer: networkd
          ethernets:
            eth0: # <-- IMPORTANT: Replace with your interface name
              dhcp4: no
              addresses:
                - 172.16.0.2/24
              routes:
                - to: default
                  via: 172.16.0.1
              nameservers:
                addresses:
                  - 172.16.0.1
        ```
    -   Apply the configuration:
        ```bash
        sudo netplan apply
        ```

## 2. Disable systemd-resolved DNS Stub

On recent versions of Ubuntu, `systemd-resolved` acts as a local DNS stub resolver and listens on port 53 by default. This conflicts with `dnsmasq`. You must disable this functionality before starting `dnsmasq`.

1.  **Edit the resolved configuration:**
    ```bash
    sudo nano /etc/systemd/resolved.conf
    ```
    -   In this file, find the line `#DNSStubListener=yes` and change it to `DNSStubListener=no`. It should look like this:
    ```ini
    [Resolve]
    #DNS=
    #FallbackDNS=
    #Domains=
    #LLMNR=no
    #MulticastDNS=no
    #DNSSEC=no
    #DNSOverTLS=no
    #Cache=no-negative
    DNSStubListener=no
    ```

2.  **Update `/etc/resolv.conf`:**
    - After disabling the stub listener, you need to point the system's DNS resolver to the correct `resolv.conf` file managed by `systemd-resolved`.
    ```bash
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    ```

3.  **Restart the service:**
    ```bash
    sudo systemctl restart systemd-resolved
    ```
    After this, port 53 will be free for `dnsmasq`.

## 3. Dnsmasq for DHCP & PXE

`dnsmasq` will provide the DHCP and TFTP services needed to boot the Talos nodes.

1.  **Install dnsmasq:**
    ```bash
    sudo apt update
    sudo apt install dnsmasq -y
    ```

2.  **Copy the configuration file:**
    -   This repository includes a pre-made `dnsmasq.conf` file. Copy it to the correct location on your server.
    -   **Important:** Before you copy, you may want to edit `seed-server/dnsmasq.conf` to adjust the `interface=` value or add your own static DHCP leases.
    ```bash
    sudo cp seed-server/dnsmasq.conf /etc/dnsmasq.conf
    ```

3.  **Create the TFTP root directory:**
    -   The `dnsmasq.conf` file specifies `/srv/tftp` as the home for our boot files. Create this directory now.
    -   **Note:** The `dnsmasq` package creates a user named `dnsmasq`, but on some systems, it does not create a corresponding group. Instead, the user is assigned to the `nogroup` group.
    ```bash
    sudo mkdir -p /srv/tftp
    sudo chown dnsmasq:dnsmasq /srv/tftp
    ```

4.  **Download the iPXE bootloader:**
    -   Sidero Metal uses the iPXE network bootloader. You need to download the correct EFI binary to your TFTP directory.
    ```bash
    sudo wget -O /srv/tftp/ipxe.efi http://boot.ipxe.org/ipxe.efi
    ```
    
5.  **Restart dnsmasq:**
    ```bash
    sudo systemctl restart dnsmasq
    ```

## 4. Disable Router DHCP

At this point, your server is ready. The final step is to disable the DHCP server on your primary router. Once you do that, the seed server will automatically start serving DHCP leases and handling PXE boot requests.

## 5. Seed Cluster (k3d & Sidero)

After the network services are running, the final step is to install `k3d` to create the small Kubernetes cluster and then deploy the Sidero Metal manifests from this repository into it. 