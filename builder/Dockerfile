FROM archlinux:base-devel

# QEMU user-mode emulation does not support pacman's seccomp download sandbox.
RUN sed -i 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed ccache git jq nvchecker pacman-contrib \
    && rm -rf /var/cache/pacman/pkg/*

COPY builder/makepkg.conf /etc/makepkg.conf.d/zz-build-repo.conf
COPY builder/common.sh builder/build.sh builder/publish.sh /usr/local/lib/dsr-aur/
RUN ln -s /usr/local/lib/dsr-aur/build.sh /usr/local/bin/dsr-build \
    && ln -s /usr/local/lib/dsr-aur/publish.sh /usr/local/bin/dsr-publish
COPY aur.txt /src/aur.txt
COPY pkgs /src/pkgs

CMD ["dsr-build", "loop"]
