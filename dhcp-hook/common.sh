# dhcp-hook/common.sh — paths and functions shared by install, uninstall and check.
# Read with source after lib/common.sh.
# shellcheck shell=bash disable=SC2034 # variables used by the scripts that load it

S="${PMN_SYSROOT:-}"
IFACE="vmbr0"
INTERFACES="$S/etc/network/interfaces"
HOSTS="$S/etc/hosts"
HOSTNAME_FILE="$S/etc/hostname"
DHCLIENT_CONF="$S/etc/dhcp/dhclient.conf"
EXIT_HOOK="$S/etc/dhcp/dhclient-exit-hooks.d/pve-hosts"
ENTER_HOOK="$S/etc/dhcp/dhclient-enter-hooks.d/pve-hosts-domain"
CERT_SCRIPT="$S/usr/local/sbin/pve-hosts-cert"
CERT_UNIT="$S/etc/systemd/system/pve-hosts-cert.service"
CERT_PEM="$S/etc/pve/local/pve-ssl.pem"

# Repository file and destination, with mode: the installation contract.
FILES="pve-hosts:$EXIT_HOOK:0644
pve-hosts-domain:$ENTER_HOOK:0644
pve-hosts-cert:$CERT_SCRIPT:0755
pve-hosts-cert.service:$CERT_UNIT:0644"

node_short() { head -n1 "$HOSTNAME_FILE" 2>/dev/null | tr -d '[:space:]'; }

# node_domain: part of the FQDN following the hostname in /etc/hosts. Same rule as the hooks.
node_domain() {
    awk -v s="$(node_short)" '
        /^[[:space:]]*#/ { next }
        {
            for (i = 2; i <= NF; i++) if (index($i, s ".") == 1) {
                d = substr($i, length(s) + 2); sub(/\.$/, "", d)
                if (d != "") { print d; exit }
            }
        }
    ' "$HOSTS" 2>/dev/null
}

# vmbr0_method: static, dhcp, manual... or empty if the stanza is missing.
vmbr0_method() {
    awk -v ifc="$IFACE" '$1 == "iface" && $2 == ifc && $3 == "inet" { print $4; exit }' "$INTERFACES"
}

# vmbr0_to_dhcp file: prints the file with the "iface vmbr0 inet static" stanza converted.
# Only changes inet static to inet dhcp and drops address, netmask and gateway of the stanza.
vmbr0_to_dhcp() {
    awk -v ifc="$IFACE" '
        /^[^[:space:]#]/ { in_st = 0 }
        $1 == "iface" && $2 == ifc && $3 == "inet" && $4 == "static" {
            in_st = 1; sub(/inet[[:space:]]+static/, "inet dhcp"); print; next
        }
        in_st && ($1 == "address" || $1 == "netmask" || $1 == "gateway") { next }
        { print }
    ' "$1"
}

# dhclient_residue: is the dhclient.conf block left by earlier versions present?
dhclient_residue() { [ -f "$DHCLIENT_CONF" ] && grep -q '^# BEGIN pve-hosts$' "$DHCLIENT_CONF"; }

# vmbr0_ip: current IPv4 address of vmbr0.
vmbr0_ip() {
    ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }'
}
