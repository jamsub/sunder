#!/bin/bash

################################################################################
# Proxmox Network Change and VM Shutdown Script
# 
# This script:
# 1. Changes the IP address of a Proxmox server using /etc/network/interfaces
# 2. Shuts down all running Proxmox VMs gracefully
# 3. Provides option to shutdown or reboot the host
#
# Requirements:
# - Proxmox VE (Debian-based)
# - Root/sudo privileges
# - ifupdown2 (default in Proxmox VE 7+)
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Detect bridge interface (typically vmbr0)
detect_bridge() {
    local bridge
    # First try to find the bridge with an IP address
    bridge=$(ip addr | grep -oP '(?<=^\d: )vmbr\d+(?=:)' | head -n1)
    
    if [[ -z "$bridge" ]]; then
        # Fallback to default
        bridge="vmbr0"
        log_warn "Could not detect bridge interface, using default: $bridge"
    else
        log_info "Detected bridge interface: $bridge"
    fi
    
    echo "$bridge"
}

# Detect physical interface
detect_physical_interface() {
    # Get the physical interface that's bridged (usually en* or eth*)
    local physical
    physical=$(ip link | grep -oP '(?<=^\d: )(en\w+|eth\d+)(?=:)' | head -n1)
    
    if [[ -z "$physical" ]]; then
        log_error "Could not detect physical network interface"
        exit 1
    fi
    
    echo "$physical"
}

# Get network configuration from user
get_network_config() {
    log_step "Network Configuration"
    echo ""
    
    # Detect interfaces
    BRIDGE=$(detect_bridge)
    PHYSICAL_INTERFACE=$(detect_physical_interface)
    
    log_info "Bridge interface: $BRIDGE"
    log_info "Physical interface: $PHYSICAL_INTERFACE"
    
    # Get current IP for reference
    CURRENT_IP=$(ip addr show "$BRIDGE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    if [[ -n "$CURRENT_IP" ]]; then
        log_info "Current IP address: $CURRENT_IP"
    fi
    
    # Get current gateway
    CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
    if [[ -n "$CURRENT_GATEWAY" ]]; then
        log_info "Current gateway: $CURRENT_GATEWAY"
    fi
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
    while true; do
        read -p "Enter subnet mask (e.g., 255.255.255.0): " SUBNET_MASK
        if validate_ip "$SUBNET_MASK"; then
            CIDR=$(mask_to_cidr "$SUBNET_MASK")
            if [[ $? -eq 0 ]]; then
                break
            fi
        else
            log_error "Invalid subnet mask format. Please try again."
        fi
    done
    
    # Prompt for gateway
    while true; do
        read -p "Enter gateway IP address: " GATEWAY
        if validate_ip "$GATEWAY"; then
            break
        else
            log_error "Invalid gateway IP address format. Please try again."
        fi
    done
    
    echo ""
    log_info "Configuration Summary:"
    echo "  Bridge: $BRIDGE"
    echo "  Physical Interface: $PHYSICAL_INTERFACE"
    echo "  New IP: $NEW_IP/$CIDR ($SUBNET_MASK)"
    echo "  Gateway: $GATEWAY"
    echo ""
    
    read -p "Is this configuration correct? (yes/no): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "Configuration cancelled by user"
        exit 0
    fi
}

# Backup existing network configuration
backup_network_config() {
    log_step "Backing up current network configuration"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/root/network_backup_${timestamp}"
    
    mkdir -p "$backup_dir"
    
    # Backup interfaces file
    if [[ -f "/etc/network/interfaces" ]]; then
        cp /etc/network/interfaces "$backup_dir/interfaces"
    else
        log_error "/etc/network/interfaces file not found!"
        exit 1
    fi
    
    # Backup hosts file
    if [[ -f "/etc/hosts" ]]; then
        cp /etc/hosts "$backup_dir/hosts"
    fi
    
    # Backup issue file if it exists
    if [[ -f "/etc/issue" ]]; then
        cp /etc/issue "$backup_dir/issue"
    fi
    
    # Backup resolv.conf if it exists
    if [[ -f "/etc/resolv.conf" ]]; then
        cp /etc/resolv.conf "$backup_dir/resolv.conf"
    fi
    
    # Backup cluster configs if they exist
    if [[ -f "/etc/pve/corosync.conf" ]]; then
        cp /etc/pve/corosync.conf "$backup_dir/corosync.conf" 2>/dev/null || true
    fi
    
    log_info "Backup created at: $backup_dir"
    BACKUP_DIR="$backup_dir"
}

# Configure network interfaces file
configure_network() {
    log_step "Configuring network interfaces"
    
    local interfaces_file="/etc/network/interfaces"
    local temp_file="/etc/network/interfaces.new"
    
    # Read existing configuration to preserve other interfaces
    local existing_config=""
    if [[ -f "$interfaces_file" ]]; then
        # Extract loopback and physical interface configs
        existing_config=$(grep -A 10 "^auto lo" "$interfaces_file" 2>/dev/null || echo "")
    fi
    
    # Create new configuration
    cat > "$temp_file" << EOF
# Network configuration generated by proxmox-network-change.sh
# Backup created at: /root/interfaces.backup.*
# Generated: $(date)

auto lo
iface lo inet loopback

auto $PHYSICAL_INTERFACE
iface $PHYSICAL_INTERFACE inet manual

auto $BRIDGE
iface $BRIDGE inet static
    address $NEW_IP/$CIDR
    gateway $GATEWAY
    bridge-ports $PHYSICAL_INTERFACE
    bridge-stp off
    bridge-fd 0
EOF

    # Add any additional bridges from original config (vmbr1, vmbr2, etc.)
    if [[ -f "$interfaces_file" ]]; then
        # Extract other bridge configurations (excluding our primary bridge)
        grep -E "^(auto|iface) vmbr" "$interfaces_file" | grep -v "$BRIDGE" > /tmp/other_bridges.txt 2>/dev/null || true
        if [[ -s /tmp/other_bridges.txt ]]; then
            echo "" >> "$temp_file"
            echo "# Additional bridges from original configuration" >> "$temp_file"
            awk '/^auto vmbr[1-9]|^iface vmbr[1-9]/{flag=1} flag{print; if(/^$/){flag=0}}' "$interfaces_file" >> "$temp_file" 2>/dev/null || true
        fi
        rm -f /tmp/other_bridges.txt
    fi
    
    log_info "Network configuration written to $temp_file"
    
    # Show the configuration
    echo ""
    log_info "New network configuration:"
    echo "----------------------------------------"
    cat "$temp_file"
    echo "----------------------------------------"
    echo ""
}

# Update /etc/hosts file
update_hosts_file() {
    log_step "Updating /etc/hosts file"
    
    local hosts_file="/etc/hosts"
    local hostname=$(hostname)
    local hostname_fqdn=$(hostname -f 2>/dev/null || echo "$hostname")
    
    # Create backup
    cp "$hosts_file" "${hosts_file}.bak"
    
    # Read current hosts file and update/add entry
    local temp_hosts="/tmp/hosts.new"
    
    # Start with standard entries
    cat > "$temp_hosts" << EOF
127.0.0.1       localhost.localdomain localhost
$NEW_IP       $hostname_fqdn $hostname

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
    
    # Preserve any additional custom entries (skip old entries for this hostname)
    if [[ -f "$hosts_file" ]]; then
        grep -v "127.0.0.1" "$hosts_file" | \
        grep -v "::1" | \
        grep -v "ip6-" | \
        grep -v "ff02::" | \
        grep -v "$hostname" | \
        grep -v "^#" | \
        grep -v "^$" >> "$temp_hosts" 2>/dev/null || true
    fi
    
    # Show what will be written
    echo ""
    log_info "New /etc/hosts content:"
    echo "----------------------------------------"
    cat "$temp_hosts"
    echo "----------------------------------------"
    echo ""
    
    # Ask for confirmation
    read -p "Update /etc/hosts file? (yes/no): " hosts_confirm
    if [[ "$hosts_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        mv "$temp_hosts" "$hosts_file"
        log_info "/etc/hosts updated successfully"
    else
        log_warn "/etc/hosts not updated"
        rm "$temp_hosts"
    fi
}

# Check and warn about cluster configuration
check_cluster_config() {
    log_step "Checking for Proxmox Cluster configuration"
    
    # Check if this node is part of a cluster
    if [[ -f "/etc/pve/corosync.conf" ]]; then
        log_warn "⚠️  CLUSTER DETECTED ⚠️"
        echo ""
        log_error "This server is part of a Proxmox cluster!"
        echo ""
        echo "Changing the IP address of a clustered node requires additional steps:"
        echo "  1. Update /etc/pve/corosync.conf (on ONE node with quorum)"
        echo "  2. Increment config_version in corosync.conf"
        echo "  3. Update /etc/hosts on ALL nodes"
        echo "  4. Update /etc/pve/priv/known_hosts"
        echo "  5. Restart pve-cluster and corosync services"
        echo ""
        log_error "This script only handles the network interface configuration."
        log_error "You MUST manually update cluster configuration files!"
        echo ""
        log_warn "For clusters, it's often safer to:"
        echo "  - Remove node from cluster"
        echo "  - Change IP address"
        echo "  - Re-join cluster with new IP"
        echo ""
        
        read -p "Do you understand the risks and want to continue? (yes/no): " cluster_confirm
        if [[ ! "$cluster_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            log_info "Exiting to prevent cluster corruption"
            exit 0
        fi
        
        # Show current cluster status
        if command -v pvecm &> /dev/null; then
            echo ""
            log_info "Current cluster status:"
            pvecm status || true
            echo ""
        fi
    else
        log_info "No cluster configuration detected - standalone server"
    fi
}

# Validate and apply network configuration
apply_network_config() {
    log_step "Applying network configuration"
    
    local temp_file="/etc/network/interfaces.new"
    local interfaces_file="/etc/network/interfaces"
    
    # Check if ifupdown2 is available
    if command -v ifreload &> /dev/null; then
        log_info "Using ifupdown2 for live network reload"
        
        # Copy temp file to actual interfaces file
        cp "$temp_file" "$interfaces_file"
        
        log_warn "Network connectivity will be interrupted briefly"
        echo ""
        log_warn "If this is a remote connection, you may lose connectivity!"
        log_warn "Make sure you have console access available."
        echo ""
        read -p "Press Enter to continue or Ctrl+C to cancel..."
        
        # Apply configuration
        if ifreload -a; then
            log_info "Network configuration applied successfully"
            sleep 2
            
            # Verify new IP is assigned
            NEW_IP_CHECK=$(ip addr show "$BRIDGE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            if [[ "$NEW_IP_CHECK" == "$NEW_IP" ]]; then
                log_info "New IP address verified: $NEW_IP_CHECK"
            else
                log_warn "IP address check shows: $NEW_IP_CHECK (expected: $NEW_IP)"
            fi
        else
            log_error "Failed to apply network configuration"
            log_warn "Restoring backup..."
            # Restore from backup
            LATEST_BACKUP=$(ls -t /root/interfaces.backup.* 2>/dev/null | head -n1)
            if [[ -n "$LATEST_BACKUP" ]]; then
                cp "$LATEST_BACKUP" "$interfaces_file"
                ifreload -a
                log_info "Backup restored"
            fi
            exit 1
        fi
    else
        log_warn "ifupdown2 not found. Configuration will be applied on next reboot."
        cp "$temp_file" "$interfaces_file"
        log_info "Configuration saved. Reboot required to apply changes."
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
    
    # Display VMs to be shutdown
    log_info "VMs to be shutdown:"
    qm list | awk 'NR>1 && $3=="running" {printf "  VM %s: %s (Status: %s)\n", $1, $2, $3}'
    echo ""
    
    read -p "Proceed with VM shutdown? (yes/no): " vm_confirm
    if [[ ! "$vm_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "VM shutdown cancelled"
        return 0
    fi
    
    # Shutdown each VM gracefully
    local shutdown_timeout=120  # 2 minutes per VM
    
    for vmid in $running_vms; do
        local vm_name
        vm_name=$(qm list | awk -v id="$vmid" '$1==id {print $2}')
        
        echo ""
        log_info "Shutting down VM $vmid ($vm_name)..."
        
        # Attempt graceful shutdown
        if qm shutdown "$vmid" &> /dev/null; then
            # Wait for VM to shutdown with timeout
            local elapsed=0
            while [[ $elapsed -lt $shutdown_timeout ]]; do
                local status
                status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
                
                if [[ "$status" == "stopped" ]]; then
                    log_info "VM $vmid shutdown successfully (${elapsed}s)"
                    break
                fi
                
                sleep 5
                elapsed=$((elapsed + 5))
                
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    log_info "Still waiting for VM $vmid... (${elapsed}s/${shutdown_timeout}s)"
                fi
            done
            
            # If still running after timeout, force stop
            status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
            if [[ "$status" != "stopped" ]]; then
                log_warn "VM $vmid did not shutdown gracefully after ${shutdown_timeout}s. Forcing stop..."
                if qm stop "$vmid" &> /dev/null; then
                    sleep 2
                    log_info "VM $vmid force stopped"
                else
                    log_error "Failed to force stop VM $vmid"
                fi
            fi
        else
            log_warn "Failed to send shutdown signal to VM $vmid. Forcing stop..."
            if qm stop "$vmid" &> /dev/null; then
                sleep 2
                log_info "VM $vmid force stopped"
            else
                log_error "Failed to force stop VM $vmid"
            fi
        fi
    done
    
    echo ""
    log_info "All VMs have been shut down"
}

# Shutdown or reboot the host
shutdown_host() {
    log_step "Host System Shutdown/Reboot"
    echo ""
    echo "Select an option:"
    echo "1) Shutdown the system"
    echo "2) Reboot the system"
    echo "3) Exit without shutdown/reboot"
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
            log_info "Exiting without shutdown or reboot"
            exit 0
            ;;
        *)
            log_error "Invalid choice. Exiting without shutdown or reboot"
            exit 1
            ;;
    esac
}

# Main execution flow
main() {
    echo ""
    echo "=========================================="
    echo "  Proxmox Network & VM Management Script"
    echo "=========================================="
    echo ""
    
    # Pre-flight checks
    check_root
    
    # Check if this is a Proxmox system
    if [[ ! -f "/etc/pve/.version" ]]; then
        log_warn "This doesn't appear to be a Proxmox VE system"
        read -p "Continue anyway? (yes/no): " cont
        if [[ ! "$cont" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            log_info "Exiting"
            exit 0
        fi
    fi
    
    # Check for cluster configuration
    check_cluster_config
    
    # Get network configuration from user
    get_network_config
    
    # Backup existing configuration
    backup_network_config
    
    # Configure network
    configure_network
    
    # Update hosts file
    update_hosts_file
    
    echo ""
    read -p "Apply network configuration now? This will change the IP address. (yes/no): " apply_confirm
    if [[ "$apply_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        apply_network_config
    else
        log_warn "Network configuration not applied. Configuration saved to /etc/network/interfaces.new"
        log_info "To apply manually:"
        log_info "  1. cp /etc/network/interfaces.new /etc/network/interfaces"
        log_info "  2. ifreload -a    (or reboot)"
    fi
    
    echo ""
    
    # Shutdown VMs
    read -p "Shutdown Proxmox VMs now? (yes/no): " vm_confirm
    if [[ "$vm_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        shutdown_vms
    else
        log_warn "VM shutdown skipped"
    fi
    
    echo ""
    
    # Shutdown or reboot
    shutdown_host
}

# Run main function
main "$@"
