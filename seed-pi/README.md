# Seed Pi Setup

This directory contains the configuration files for the Raspberry Pi that will act as the "seed cluster" for the main Talos homelab. Its primary roles are to run the Sidero Metal controller and to provide DHCP/PXE services to the network.

## 1. Initial Pi Setup

1.  Install a standard Raspberry Pi OS Lite (64-bit) image.
2.  Boot the Pi and ensure it has network connectivity.
3.  **Set a static IP address:**
    -   Edit the network configuration file (e.g., `/etc/dhcpcd.conf` on older Raspberry Pi OS, or use `nmcli` on newer versions).
    -   Assign the following static IP configuration:
        -   IP Address: `172.16.0.2/24`
        -   Router/Gateway: `172.16.0.1`
        -   DNS Server: `172.16.0.1`

## 2. Dnsmasq for DHCP & PXE

`dnsmasq` will provide the DHCP and TFTP services needed to boot the Talos nodes.

1.  **Install dnsmasq:**
    ```bash
    sudo apt update
    sudo apt install dnsmasq -y
    ```

2.  **Copy the configuration file:**
    -   Copy the contents of `seed-pi/dnsmasq/dnsmasq.conf` from this repository to `/etc/dnsmasq.conf` on the Raspberry Pi.
    ```bash
    sudo cp /path/to/repo/seed-pi/dnsmasq/dnsmasq.conf /etc/dnsmasq.conf
    ```

3.  **Create the TFTP root directory:**
    -   The `dnsmasq.conf` file specifies `/srv/tftp` as the home for our boot files. Create this directory now.
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

## 3. Disable Router DHCP

At this point, your Pi is ready. The final step is to disable the DHCP server on your D-Link router. Once you do that, the Pi will automatically start serving DHCP leases and handling PXE boot requests.

## 4. Seed Cluster (k3d & Sidero)

After the network services are running, the final step is to install `k3d` to create the small Kubernetes cluster and then deploy the Sidero Metal manifests from this repository into it. 