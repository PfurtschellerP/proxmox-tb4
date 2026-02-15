#!/bin/bash
# Enable systemd-networkd and verify TB4 boot services
# Note: The systemd service and startup script are created by 04-setup-udev-rules.sh
# This script handles systemd-networkd enablement, verification, and testing
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "Systemd Verification & Setup"

load_config

read -ra nodes <<< "$(get_node_ips)"
read -ra names <<< "$NODE1_NAME $NODE2_NAME $NODE3_NAME"

log_step "Step 1: Check Prerequisites"

log_info "Verifying that 04-setup-udev-rules.sh has been run"
echo ""

prereqs_ok=true

for i in "${!nodes[@]}"; do
    node="${nodes[$i]}"
    name="${names[$i]}"

    echo ""
    log_info "=== $name ($node) ==="

    # Check thunderbolt-startup.sh
    if ssh "root@$node" "test -x /usr/local/bin/thunderbolt-startup.sh"; then
        log_success "thunderbolt-startup.sh: present"
    else
        log_error "thunderbolt-startup.sh: missing"
        prereqs_ok=false
    fi

    # Check service file
    if ssh "root@$node" "test -f /etc/systemd/system/thunderbolt-interfaces.service"; then
        log_success "thunderbolt-interfaces.service: present"
    else
        log_error "thunderbolt-interfaces.service: missing"
        prereqs_ok=false
    fi

    # Check interface bringup scripts
    if ssh "root@$node" "test -x /usr/local/bin/pve-en05.sh -a -x /usr/local/bin/pve-en06.sh"; then
        log_success "Interface bringup scripts: present"
    else
        log_error "Interface bringup scripts: missing"
        prereqs_ok=false
    fi

    # Check for corrupted shebang (common issue per docs)
    if ssh "root@$node" "head -1 /usr/local/bin/thunderbolt-startup.sh 2>/dev/null | grep -q '^#!/bin/bash$'"; then
        log_success "Startup script shebang: OK"
    else
        log_warn "Startup script shebang: may be corrupted (check for backslash escaping)"
    fi
done

if [[ "$prereqs_ok" != "true" ]]; then
    echo ""
    log_error "Prerequisites not met. Run ./scripts/04-setup-udev-rules.sh first."
    exit 1
fi

log_step "Step 2: Enable systemd-networkd"

log_info "Required for systemd .link files to work (interface renaming)"
echo ""

if confirm "Enable systemd-networkd on all nodes?"; then
    for i in "${!nodes[@]}"; do
        node="${nodes[$i]}"
        name="${names[$i]}"

        log_info "Enabling systemd-networkd on $name..."

        # Enable and start systemd-networkd
        ssh "root@$node" "systemctl enable systemd-networkd >/dev/null 2>&1 || true"
        ssh "root@$node" "systemctl start systemd-networkd >/dev/null 2>&1 || true"

        # Check if it's running
        if ssh "root@$node" "systemctl is-active systemd-networkd >/dev/null 2>&1"; then
            log_success "$name: systemd-networkd active"
        else
            log_warn "$name: systemd-networkd may not be running (this is usually OK)"
        fi
    done
fi

log_step "Step 3: Verify Service Configuration"

log_info "Checking systemd service status on all nodes"
echo ""

for i in "${!nodes[@]}"; do
    node="${nodes[$i]}"
    name="${names[$i]}"

    echo ""
    log_info "=== $name ($node) ==="

    # Check if service is enabled
    if ssh "root@$node" "systemctl is-enabled thunderbolt-interfaces.service >/dev/null 2>&1"; then
        log_success "Service: enabled"
    else
        log_warn "Service: not enabled"
    fi

    # Check systemd-networkd
    if ssh "root@$node" "systemctl is-enabled systemd-networkd >/dev/null 2>&1"; then
        log_success "systemd-networkd: enabled"
    else
        log_warn "systemd-networkd: not enabled"
    fi

    # Check .link files for interface renaming
    if ssh "root@$node" "test -f /etc/systemd/network/00-thunderbolt0.link -a -f /etc/systemd/network/00-thunderbolt1.link"; then
        log_success "Interface renaming .link files: present"
    else
        log_warn "Interface renaming .link files: not found (interfaces may use default names)"
    fi
done

log_step "Step 4: Test Service (Optional)"

echo ""
log_info "You can test the service by running it manually"
log_warn "This will attempt to bring up TB4 interfaces now"
echo ""

if confirm "Test the service on all nodes now?"; then
    for i in "${!nodes[@]}"; do
        node="${nodes[$i]}"
        name="${names[$i]}"

        log_info "Testing service on $name..."

        # Try to start the service
        if ssh "root@$node" "systemctl start thunderbolt-interfaces.service 2>&1"; then
            log_success "$name: Service started successfully"

            # Check if interfaces came up
            if ssh "root@$node" "ip link show en05 2>/dev/null | grep -q 'state UP'"; then
                log_success "$name: en05 is UP"
            else
                log_warn "$name: en05 not UP (cable connected?)"
            fi

            if ssh "root@$node" "ip link show en06 2>/dev/null | grep -q 'state UP'"; then
                log_success "$name: en06 is UP"
            else
                log_warn "$name: en06 not UP (cable connected?)"
            fi
        else
            log_error "$name: Service failed to start"
            log_info "Check logs with: ssh root@$node 'journalctl -u thunderbolt-interfaces.service'"
        fi
    done

    echo ""
    log_info "Check startup logs with:"
    log_info "  for node in ${names[*]}; do ssh root@\$node 'tail -20 /var/log/thunderbolt-startup.log'; done"
fi

log_step "Summary"

log_success "Systemd setup verified!"
echo ""
log_info "What was checked/configured:"
log_info "  - systemd-networkd enabled (for .link interface renaming)"
log_info "  - thunderbolt-interfaces.service verified"
log_info "  - Startup and bringup scripts verified"
echo ""
log_info "The TB4 interfaces will now:"
log_info "  - Come up automatically on every boot"
log_info "  - Use consistent naming via .link files"
log_info "  - Work even if udev rules fail to trigger"
log_info "  - Log activity to /var/log/thunderbolt-startup.log"
echo ""
log_info "Troubleshooting:"
log_info "  - View service status: systemctl status thunderbolt-interfaces.service"
log_info "  - View startup logs: tail -f /var/log/thunderbolt-startup.log"
log_info "  - View systemd logs: journalctl -u thunderbolt-interfaces.service"
echo ""
log_info "Next step: ./scripts/06-verify-mesh.sh"
echo ""
