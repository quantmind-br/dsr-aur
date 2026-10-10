FROM archlinux:base-devel

# QEMU user-mode emulation does not support pacman's seccomp download sandbox.
RUN sed -i 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed ccache git \
    && rm -rf /var/cache/pacman/pkg/* \
    && useradd --create-home builder

COPY builder/makepkg.conf /etc/makepkg.conf.d/build-repo.conf
COPY builder/build-repo.sh /usr/local/bin/build-repo
COPY aur.txt /src/aur.txt
COPY pkgs /src/pkgs

ENTRYPOINT ["build-repo"]
CMD ["loop"]
