#!/bin/bash

################################################################################
# Proxmox Network Change and VM Shutdown Script
# 
# This script:
# 1. Changes the IP address of an Ubuntu server using Netplan
# 2. Shuts down all running Proxmox VMs gracefully
# 3. Provides option to shutdown or reboot the host
#
# Requirements:
# - Ubuntu with Netplan (18.04+)
# - Proxmox VE installed
# - Root/sudo privileges
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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

# Detect primary network interface
detect_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [[ -z "$interface" ]]; then
        log_error "Could not detect primary network interface"
        exit 1
    fi
    
    echo "$interface"
}

# Get network configuration from user
get_network_config() {
    log_step "Network Configuration"
    echo ""
    
    # Detect current interface
    INTERFACE=$(detect_interface)
    log_info "Detected network interface: $INTERFACE"
    
    # Get current IP for reference
    CURRENT_IP=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    if [[ -n "$CURRENT_IP" ]]; then
        log_info "Current IP address: $CURRENT_IP"
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
    
    # Prompt for DNS servers (optional)
    read -p "Enter DNS servers (comma-separated, press Enter for 8.8.8.8,8.8.4.4): " DNS_INPUT
    if [[ -z "$DNS_INPUT" ]]; then
        DNS_SERVERS="8.8.8.8,8.8.4.4"
    else
        DNS_SERVERS="$DNS_INPUT"
    fi
    
    echo ""
    log_info "Configuration Summary:"
    echo "  Interface: $INTERFACE"
    echo "  New IP: $NEW_IP/$CIDR"
    echo "  Gateway: $GATEWAY"
    echo "  DNS: $DNS_SERVERS"
    echo ""
    
    read -p "Is this configuration correct? (yes/no): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        log_warn "Configuration cancelled by user"
        exit 0
    fi
}

# Backup existing netplan configuration
backup_netplan() {
    log_step "Backing up current Netplan configuration"
    
    local netplan_dir="/etc/netplan"
    local backup_dir="/root/netplan_backup_$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$backup_dir"
    cp -r "$netplan_dir"/* "$backup_dir/" 2>/dev/null || true
    
    log_info "Backup created at: $backup_dir"
}

# Configure netplan with new IP settings
configure_netplan() {
    log_step "Configuring Netplan with new IP settings"
    
    local netplan_file
    
    # Find the active netplan configuration file
    if [[ -f "/etc/netplan/00-installer-config.yaml" ]]; then
        netplan_file="/etc/netplan/00-installer-config.yaml"
    elif [[ -f "/etc/netplan/50-cloud-init.yaml" ]]; then
        netplan_file="/etc/netplan/50-cloud-init.yaml"
    elif [[ -f "/etc/netplan/01-netcfg.yaml" ]]; then
        netplan_file="/etc/netplan/01-netcfg.yaml"
    else
        # Create new configuration file
        netplan_file="/etc/netplan/00-installer-config.yaml"
        log_warn "No existing netplan configuration found. Creating new file: $netplan_file"
    fi
    
    log_info "Using netplan file: $netplan_file"
    
    # Convert DNS servers to YAML array format
    IFS=',' read -ra DNS_ARRAY <<< "$DNS_SERVERS"
    DNS_YAML=""
    for dns in "${DNS_ARRAY[@]}"; do
        dns=$(echo "$dns" | xargs)  # Trim whitespace
        DNS_YAML="${DNS_YAML}        - ${dns}\n"
    done
    
    # Create new netplan configuration
    cat > "$netplan_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $NEW_IP/$CIDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
$(echo -e "$DNS_YAML")
EOF
    
    # Set proper permissions
    chmod 600 "$netplan_file"
    
    log_info "Netplan configuration updated"
    
    # Disable cloud-init network management if present
    if [[ -d "/etc/cloud/cloud.cfg.d" ]]; then
        cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << EOF
network: {config: disabled}
EOF
        log_info "Disabled cloud-init network management"
    fi
    
    # Validate netplan configuration
    log_step "Validating Netplan configuration"
    if netplan generate; then
        log_info "Netplan configuration is valid"
    else
        log_error "Netplan configuration validation failed"
        exit 1
    fi
}

# Apply netplan configuration
apply_netplan() {
    log_step "Applying Netplan configuration"
    log_warn "Network connectivity will be interrupted briefly"
    
    if netplan apply; then
        log_info "Netplan configuration applied successfully"
        sleep 2
        
        # Verify new IP is assigned
        NEW_IP_CHECK=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [[ "$NEW_IP_CHECK" == "$NEW_IP" ]]; then
            log_info "New IP address verified: $NEW_IP_CHECK"
        else
            log_warn "IP address check shows: $NEW_IP_CHECK (expected: $NEW_IP)"
        fi
    else
        log_error "Failed to apply Netplan configuration"
        exit 1
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
    
    # Shutdown each VM gracefully
    local shutdown_timeout=120  # 2 minutes per VM
    
    for vmid in $running_vms; do
        local vm_name
        vm_name=$(qm list | awk -v id="$vmid" '$1==id {print $2}')
        
        log_info "Shutting down VM $vmid ($vm_name)..."
        
        # Attempt graceful shutdown
        if qm shutdown "$vmid" &> /dev/null; then
            # Wait for VM to shutdown with timeout
            local elapsed=0
            while [[ $elapsed -lt $shutdown_timeout ]]; do
                local status
                status=$(qm status "$vmid" | awk '{print $2}')
                
                if [[ "$status" == "stopped" ]]; then
                    log_info "VM $vmid shutdown successfully"
                    break
                fi
                
                sleep 5
                elapsed=$((elapsed + 5))
                
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    log_info "Still waiting for VM $vmid... (${elapsed}s elapsed)"
                fi
            done
            
            # If still running after timeout, force stop
            status=$(qm status "$vmid" | awk '{print $2}')
            if [[ "$status" != "stopped" ]]; then
                log_warn "VM $vmid did not shutdown gracefully. Forcing stop..."
                qm stop "$vmid"
                sleep 2
                log_info "VM $vmid force stopped"
            fi
        else
            log_warn "Failed to send shutdown signal to VM $vmid. Forcing stop..."
            qm stop "$vmid"
            sleep 2
            log_info "VM $vmid force stopped"
        fi
    done
    
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
    
    # Get network configuration from user
    get_network_config
    
    # Backup existing configuration
    backup_netplan
    
    # Configure and apply new network settings
    configure_netplan
    
    echo ""
    read -p "Apply network configuration now? This will change the IP address. (yes/no): " apply_confirm
    if [[ "$apply_confirm" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        apply_netplan
    else
        log_warn "Network configuration not applied. Changes saved but not activated."
        log_info "Run 'sudo netplan apply' manually to activate changes"
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
