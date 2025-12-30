#!/bin/bash

################################################################################
# Proxmox Network Change and VM Shutdown Script - TESTED VERSION
# 
# This script:
# 1. Changes the IP address of a Proxmox server using /etc/network/interfaces
# 2. Updates /etc/hosts file
# 3. Shuts down all running Proxmox VMs gracefully
# 4. Provides option to shutdown or reboot the host
#
# Tested on: Proxmox VE (Debian-based)
# Requirements:
# - Root/sudo privileges
# - ifupdown2 (default in Proxmox VE 7+)
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Validate IP address format
validate_ip() {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Convert subnet mask to CIDR notation
mask_to_cidr() {
    local mask=$1
    local nbits=0
    local IFS=.
    for dec in $mask ; do
        case $dec in
            255) nbits=$((nbits + 8));;
            254) nbits=$((nbits + 7));;
            252) nbits=$((nbits + 6));;
            248) nbits=$((nbits + 5));;
            240) nbits=$((nbits + 4));;
            224) nbits=$((nbits + 3));;
            192) nbits=$((nbits + 2));;
            128) nbits=$((nbits + 1));;
            0);;
            *) log_error "Invalid subnet mask: $mask"; return 1;;
        esac
    done
    echo "$nbits"
}

# Detect current network configuration
detect_current_config() {
    log_step "Detecting current network configuration"
    
    # Get bridge interface (usually vmbr0)
    BRIDGE=$(grep "^auto vmbr" /etc/network/interfaces | grep -v "^#" | head -n1 | awk '{print $2}')
    if [[ -z "$BRIDGE" ]]; then
        log_error "Could not detect bridge interface"
        exit 1
    fi
    log_info "Bridge interface: $BRIDGE"
    
    # Get current IP address
    CURRENT_IP=$(grep "address" /etc/network/interfaces | grep -v "^#" | head -n1 | awk '{print $2}')
    if [[ -n "$CURRENT_IP" ]]; then
        log_info "Current IP address: $CURRENT_IP"
    fi
    
    # Get current netmask
    CURRENT_NETMASK=$(grep "netmask" /etc/network/interfaces | grep -v "^#" | head -n1 | awk '{print $2}')
    if [[ -n "$CURRENT_NETMASK" ]]; then
        log_info "Current netmask: $CURRENT_NETMASK"
    fi
    
    # Get current gateway
    CURRENT_GATEWAY=$(grep "gateway" /etc/network/interfaces | grep -v "^#" | head -n1 | awk '{print $2}')
    if [[ -n "$CURRENT_GATEWAY" ]]; then
        log_info "Current gateway: $CURRENT_GATEWAY"
    fi
    
    # Get bridge-ports
    BRIDGE_PORTS=$(grep "bridge-ports" /etc/network/interfaces | grep -v "^#" | head -n1 | awk '{print $2}')
    if [[ -n "$BRIDGE_PORTS" ]]; then
        log_info "Bridge ports: $BRIDGE_PORTS"
    fi
    
    # Get hostname
    HOSTNAME=$(hostname)
    HOSTNAME_FQDN=$(hostname -f 2>/dev/null || echo "${HOSTNAME}.local")
    log_info "Hostname: $HOSTNAME ($HOSTNAME_FQDN)"
    
    echo ""
}

# Get network configuration from user
get_network_config() {
    log_step "New Network Configuration"
    echo ""
    
    # Prompt for new IP address
    while true; do
        read -p "Enter new IP address: " NEW_IP
        if validate_ip "$NEW_IP"; then
            break
        else
            log_error "Invalid IP address format. Please try again."
        fi
    done
    
    # Prompt for subnet mask
    if [[ -n "$CURRENT_NETMASK" ]]; then
        read -p "Enter subnet mask [${CURRENT_NETMASK}]: " SUBNET_MASK
        SUBNET_MASK=${SUBNET_MASK:-$CURRENT_NETMASK}
    else
        read -p "Enter subnet mask (e.g., 255.255.255.0): " SUBNET_MASK
    fi
    
    while ! validate_ip "$SUBNET_MASK"; do
        log_error "Invalid subnet mask format. Please try again."
        read -p "Enter subnet mask: " SUBNET_MASK
    done
    
    # Prompt for gateway
    if [[ -n "$CURRENT_GATEWAY" ]]; then
        read -p "Enter gateway IP address [${CURRENT_GATEWAY}]: " GATEWAY
        GATEWAY=${GATEWAY:-$CURRENT_GATEWAY}
    else
        read -p "Enter gateway IP address: " GATEWAY
    fi
    
    while ! validate_ip "$GATEWAY"; do
        log_error "Invalid gateway IP address format. Please try again."
        read -p "Enter gateway IP address: " GATEWAY
    done
    
    echo ""
    log_info "Configuration Summary:"
    echo "  Bridge: $BRIDGE"
    echo "  Bridge Ports: $BRIDGE_PORTS"
    echo "  Current IP: $CURRENT_IP"
    echo "  New IP: $NEW_IP"
    echo "  Netmask: $SUBNET_MASK"
    echo "  Gateway: $GATEWAY"
    echo ""
    
    read -p "Is this configuration correct? (yes/no): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "Configuration cancelled by user"
        exit 0
    fi
}

# Backup current configuration
backup_config() {
    log_step "Backing up current configuration"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [[ -f "/etc/network/interfaces" ]]; then
        cp /etc/network/interfaces "/root/interfaces.backup.${timestamp}"
        log_info "Backed up: /root/interfaces.backup.${timestamp}"
    fi
    
    if [[ -f "/etc/hosts" ]]; then
        cp /etc/hosts "/root/hosts.backup.${timestamp}"
        log_info "Backed up: /root/hosts.backup.${timestamp}"
    fi
    
    BACKUP_TIMESTAMP=$timestamp
    echo ""
}

# Update /etc/network/interfaces
update_interfaces() {
    log_step "Updating /etc/network/interfaces"
    
    # Use sed to replace the IP address line
    sed -i "s/^\s*address\s\+${CURRENT_IP}/        address ${NEW_IP}/" /etc/network/interfaces
    
    # Update netmask if it changed
    if [[ -n "$CURRENT_NETMASK" ]]; then
        sed -i "s/^\s*netmask\s\+${CURRENT_NETMASK}/        netmask ${SUBNET_MASK}/" /etc/network/interfaces
    fi
    
    # Update gateway if it changed
    if [[ -n "$CURRENT_GATEWAY" ]]; then
        sed -i "s/^\s*gateway\s\+${CURRENT_GATEWAY}/        gateway ${GATEWAY}/" /etc/network/interfaces
    fi
    
    log_info "Updated /etc/network/interfaces"
    
    # Show relevant lines
    echo ""
    log_info "New configuration in /etc/network/interfaces:"
    echo "----------------------------------------"
    grep -A 6 "auto ${BRIDGE}" /etc/network/interfaces | grep -v "^#"
    echo "----------------------------------------"
    echo ""
}

# Update /etc/hosts
update_hosts() {
    log_step "Updating /etc/hosts"
    
    # Use sed to replace the IP address for the hostname
    sed -i "s/^${CURRENT_IP}\s\+/${NEW_IP} /" /etc/hosts
    
    log_info "Updated /etc/hosts"
    
    # Show the updated line
    echo ""
    log_info "New entry in /etc/hosts:"
    echo "----------------------------------------"
    grep "${NEW_IP}" /etc/hosts
    echo "----------------------------------------"
    echo ""
}

# Apply network configuration
apply_network() {
    log_step "Applying network configuration"
    
    log_warn "Network connectivity will be interrupted briefly"
    echo ""
    
    # Check if ifreload is available
    if ! command -v ifreload &> /dev/null; then
        log_error "ifreload command not found. You may need to reboot to apply changes."
        read -p "Reboot now to apply changes? (yes/no): " reboot_now
        if [[ "$reboot_now" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            log_info "Rebooting in 5 seconds..."
            sleep 5
            reboot
        else
            log_warn "Configuration saved but not applied. Reboot required."
            exit 0
        fi
    fi
    
    read -p "Apply network configuration now? (yes/no): " apply_confirm
    if [[ ! "$apply_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "Network configuration not applied"
        log_info "To apply manually, run: ifreload -a"
        exit 0
    fi
    
    # Apply configuration
    if ifreload -a 2>&1; then
        sleep 2
        log_info "Network configuration applied successfully"
        
        # Verify new IP
        NEW_IP_CHECK=$(ip addr show "$BRIDGE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [[ "$NEW_IP_CHECK" == "$NEW_IP" ]]; then
            log_info "✓ Verified new IP: $NEW_IP_CHECK"
        else
            log_warn "IP verification: Expected $NEW_IP, got $NEW_IP_CHECK"
        fi
        
        # Test gateway
        if ping -c 2 "$GATEWAY" &> /dev/null; then
            log_info "✓ Gateway is reachable: $GATEWAY"
        else
            log_warn "Cannot ping gateway: $GATEWAY"
        fi
        
        # Check web service
        if systemctl is-active --quiet pveproxy; then
            log_info "✓ Proxmox web service is running"
            log_info "  Access at: https://${NEW_IP}:8006"
        else
            log_warn "Proxmox web service may need restart"
        fi
    else
        log_error "Failed to apply network configuration"
        log_warn "Restoring backups..."
        
        cp "/root/interfaces.backup.${BACKUP_TIMESTAMP}" /etc/network/interfaces
        cp "/root/hosts.backup.${BACKUP_TIMESTAMP}" /etc/hosts
        ifreload -a
        
        log_info "Backup restored. Configuration reverted."
        exit 1
    fi
    
    echo ""
}

# Check for cluster
check_cluster() {
    if [[ -f "/etc/pve/corosync.conf" ]]; then
        log_warn "⚠️  CLUSTER DETECTED ⚠️"
        echo ""
        log_error "This server is part of a Proxmox cluster!"
        echo ""
        echo "You must ALSO manually update:"
        echo "  1. /etc/pve/corosync.conf (increment config_version!)"
        echo "  2. /etc/hosts on ALL cluster nodes"
        echo "  3. Restart pve-cluster and corosync services"
        echo ""
        log_warn "Refer to FILE_REFERENCE_GUIDE.md for cluster procedures"
        echo ""
        
        read -p "Do you understand and want to continue? (yes/no): " cluster_confirm
        if [[ ! "$cluster_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            log_info "Exiting"
            exit 0
        fi
    fi
}

# Shutdown all Proxmox VMs
shutdown_vms() {
    log_step "Shutting down Proxmox Virtual Machines"
    
    # Check if qm command exists
    if ! command -v qm &> /dev/null; then
        log_warn "Proxmox (qm) command not found. Skipping VM shutdown."
        return 0
    fi
    
    # Get list of running VMs
    local running_vms
    running_vms=$(qm list | awk 'NR>1 && $3=="running" {print $1}')
    
    if [[ -z "$running_vms" ]]; then
        log_info "No running VMs found"
        return 0
    fi
    
    local vm_count
    vm_count=$(echo "$running_vms" | wc -l)
    log_info "Found $vm_count running VM(s)"
    echo ""
    
    # Display VMs
    log_info "Running VMs:"
    qm list | awk 'NR>1 && $3=="running" {printf "  VM %s: %s (Status: %s)\n", $1, $2, $3}'
    echo ""
    
    read -p "Shutdown all VMs? (yes/no): " vm_confirm
    if [[ ! "$vm_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "VM shutdown cancelled"
        return 0
    fi
    
    # Shutdown timeout
    local shutdown_timeout=120
    
    for vmid in $running_vms; do
        local vm_name
        vm_name=$(qm list | awk -v id="$vmid" '$1==id {print $2}')
        
        echo ""
        log_info "Shutting down VM $vmid ($vm_name)..."
        
        # Attempt graceful shutdown
        if qm shutdown "$vmid" &> /dev/null; then
            local elapsed=0
            while [[ $elapsed -lt $shutdown_timeout ]]; do
                local status
                status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
                
                if [[ "$status" == "stopped" ]]; then
                    log_info "✓ VM $vmid shutdown successfully (${elapsed}s)"
                    break
                fi
                
                sleep 5
                elapsed=$((elapsed + 5))
                
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    log_info "  Waiting for VM $vmid... (${elapsed}s/${shutdown_timeout}s)"
                fi
            done
            
            # Force stop if still running
            status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
            if [[ "$status" != "stopped" ]]; then
                log_warn "VM $vmid did not shutdown gracefully. Forcing stop..."
                qm stop "$vmid" &> /dev/null
                sleep 2
                log_info "✓ VM $vmid force stopped"
            fi
        else
            log_warn "Failed to shutdown VM $vmid. Forcing stop..."
            qm stop "$vmid" &> /dev/null
            sleep 2
            log_info "✓ VM $vmid force stopped"
        fi
    done
    
    echo ""
    log_info "All VMs have been shut down"
}

# Shutdown or reboot host
shutdown_host() {
    log_step "Host System Options"
    echo ""
    echo "Select an option:"
    echo "1) Shutdown the system"
    echo "2) Reboot the system"
    echo "3) Exit (keep system running)"
    echo ""
    
    read -p "Enter your choice (1/2/3): " choice
    
    case $choice in
        1)
            log_info "Initiating system shutdown in 10 seconds..."
            log_warn "Press Ctrl+C to cancel"
            sleep 10
            shutdown -h now
            ;;
        2)
            log_info "Initiating system reboot in 10 seconds..."
            log_warn "Press Ctrl+C to cancel"
            sleep 10
            reboot
            ;;
        3)
            log_info "Exiting - system remains running"
            exit 0
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
}

# Main execution
main() {
    echo ""
    echo "=========================================="
    echo "  Proxmox Network Change Script"
    echo "  Tested Working Version"
    echo "=========================================="
    echo ""
    
    # Pre-flight checks
    check_root
    
    # Check for cluster
    check_cluster
    
    # Detect current configuration
    detect_current_config
    
    # Get new configuration from user
    get_network_config
    
    # Create backups
    backup_config
    
    # Update configuration files
    update_interfaces
    update_hosts
    
    # Apply network configuration
    apply_network
    
    echo ""
    read -p "Shutdown Proxmox VMs? (yes/no): " vm_choice
    if [[ "$vm_choice" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        shutdown_vms
    else
        log_info "VM shutdown skipped"
    fi
    
    echo ""
    
    # Shutdown or reboot
    shutdown_host
}

# Run main function
main "$@"
