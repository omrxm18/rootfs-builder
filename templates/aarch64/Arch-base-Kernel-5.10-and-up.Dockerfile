# Dockerfile (Arch Linux Base)
# Stage 1: Build and customize the rootfs for development (Base - Arch Linux)
ARG TARGETPLATFORM
ARG SYSTEMD_TAG=257.8-1

FROM ogarcia/archlinux AS systemd-builder
ARG SYSTEMD_TAG
RUN pacman -Syu --noconfirm base-devel git meson sudo && \
    useradd -m builder && \
    echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
USER builder
WORKDIR /home/builder

# 1. Fetch the packaging repo
RUN git clone https://gitlab.archlinux.org/archlinux/packaging/packages/systemd.git && \
    cd systemd && git checkout "$SYSTEMD_TAG"

# 2. Adapt the PKGBUILD for aarch64
RUN cd systemd && sed -i \
      -e "s/ 'lib32-gcc-libs'//" \
      -e "s/ 'linux-headers'//" \
      -e 's/-Dbpf-framework=enabled/-Dbpf-framework=disabled/' \
      -e '/-Dvmlinux-h/d' \
      -e 's/-Dbootloader=enabled/-Dbootloader=disabled/' \
      -e 's/-Dman=enabled/-Dman=disabled/' \
      -e '/^  meson install -C build/a\  mkdir -p "$pkgdir"/usr/share/man/{man1,man3,man8}\n  touch "$pkgdir"/usr/share/man/man1/{ukify,resolvconf}.1 "$pkgdir"/usr/share/man/man8/{halt,poweroff,reboot,shutdown}.8' \
      -e '/^package_systemd-sysvcompat() {/a\  mkdir -p build/man; touch build/man/{halt,poweroff,reboot,shutdown}.8' \
      PKGBUILD && \
    grep -n 'Dman=\|touch' PKGBUILD

# 3. Download and extract the upstream source (no build yet)
RUN cd systemd && \
    makepkg -odA --noconfirm --skippgpcheck

# 4. Patch the extracted source (this is the snippet you asked about)
RUN cd systemd && \
    sed -i 's/-Werror=override-init/-Wno-error=override-init/' src/systemd/meson.build && \
    grep -q 'Wno-error=override-init' src/systemd/meson.build && \
    grep -n 'XMLParser' src/systemd/tools/xml_helper.py && \
    sed -i 's/XMLParser(/XMLParser(load_dtd=True, /' src/systemd/tools/xml_helper.py && \
    grep -q 'load_dtd=True' src/systemd/tools/xml_helper.py

# 5. Compile and package
RUN cd systemd && MAKEFLAGS="-j$(nproc)" makepkg -esA --noconfirm --nocheck --skippgpcheck

# 6. Collect the three packages we need into a known directory
RUN mkdir -p /home/builder/out && \
    find /home/builder -type f \
        \( -name 'systemd-257*.pkg.tar.*' \
           -o -name 'systemd-libs-257*.pkg.tar.*' \
           -o -name 'systemd-sysvcompat-257*.pkg.tar.*' \) \
        -exec cp -v {} /home/builder/out/ \; && \
    ls /home/builder/out/* > /dev/null

FROM ogarcia/archlinux AS customizer

COPY --from=systemd-builder /home/builder/out/ /tmp/pkgs/

# Update base system and install key packages
RUN pacman -Syu --noconfirm && \
    sed 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf > /tmp/pacman-nosig.conf && \
    pacman --config /tmp/pacman-nosig.conf -U --noconfirm /tmp/pkgs/*.pkg.tar.* && \
    sed -i 's/^#\?IgnorePkg.*/IgnorePkg = systemd systemd-libs systemd-sysvcompat/' /etc/pacman.conf && \
    grep -q '^IgnorePkg' /etc/pacman.conf && \
    rm -rf /tmp/pacman-nosig.conf /tmp/pkgs

RUN pacman -S --noconfirm \
    # Core utilities
    bash dialog coreutils file findutils grep sed \
    gawk curl wget ca-certificates bash-completion \
    # do not install systemd
    dbus \
    # System tools
    htop vim nano git sudo openssh net-tools iptables \
    iputils iproute2 bind usbutils pciutils lsof psmisc dhcpcd \
    procps-ng fastfetch kmod \
    # Logging & Rotation
    logrotate \
    # Development tools
    base-devel cmake git clang llvm \
    valgrind strace ltrace \
    # Python
    python python-pip \
    # Docker
    docker docker-compose \
    && pacman -Scc --noconfirm

# Copy our bashrc script to the rootfs
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# Make scripts executable
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Configure legacy iptables (MANDATORY for Android compatibility)
RUN ln -sf /usr/bin/iptables-legacy /usr/bin/iptables && \
    ln -sf /usr/bin/ip6tables-legacy /usr/bin/ip6tables && \
    ln -sf /usr/bin/arptables-legacy /usr/bin/arptables && \
    ln -sf /usr/bin/ebtables-legacy /usr/bin/ebtables

# Configure locales and environment
RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen && \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
    # Configure SSH (Disable Root Login)
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Fix DHCP in the container
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# Apply Android compatibility fixes (Systemd and Udev)
RUN <<EOF_RUN
# --- 1. General Fixes ---
# Android network group setup (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# Arch doesn't have _apt user by default, but if some tool creates it:
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

# --- 2. Systemd-Specific Fixes ---
# Mask problematic services for Android kernels
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket
# dhcpcd replacing systemd-networkd
ln -sf /usr/lib/systemd/system/dhcpcd@.service /etc/systemd/system/multi.user-target.wants/dhcpcd@eth0.service
# mask networkd, replacement above
ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket

# dhcpcd.conf
echo "allowinterfaces eth0" >> /etc/dhcpcd.conf
echo "nohook resolv.conf" >> /etc/dhcpcd.conf # let systemd-resolvd take control over /etc/resolv.conf

# Journald configuration (skip Audit, KMsg, etc)
cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

# Enable essential services
mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"
for service in dbus.service systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

# Disable power button handling in systemd-logind
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# Apply udev overrides
# 1. Trigger override (Prevents coldplugging Android hardware)
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. Read-only path overrides to prevent failures
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Keep network services out of host and none modes; every mode with its own
# network needs a DHCP client, so list the modes to skip, not the ones to run in
# Prevents cellular network breakage when running in host network mode
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q '^net_mode=' /run/droidspaces/container.config && ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config"
EOF
    fi
done

# Configure logrotate for Android
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Final cleanup
RUN pacman -Scc --noconfirm && \
    rm -rf /var/cache/pacman/pkg/*
    
RUN systemctl --version | head -1 | grep -q 'systemd 257' && \
        pacman -Q systemd systemd-libs

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Arch Linux - Base" \
      droidspaces.distro="Arch" \
      droidspaces.description="Arch Linux rootfs with basic packages, development tools and Docker (Runs on Kernel 5.10 and above only)." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
