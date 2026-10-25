FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates build-essential cmake ninja-build git openssh-client python3 python3-venv \
    clang-20 clangd-20 clang-format-20 lldb-20 lld-20 llvm-20-dev llvm-20-tools libclang-20-dev \
    libzstd-dev zlib1g-dev libxml2-dev libedit-dev libncurses-dev libcurl4-openssl-dev \
    libgtest-dev protobuf-compiler libprotobuf-dev libprotoc-dev \
    libgtk-4-dev librsvg2-2 fonts-dejavu-core libgirepository1.0-dev gobject-introspection pkg-config \
    ffmpeg gstreamer1.0-libav gstreamer1.0-plugins-good xvfb xauth dbus-x11 ccache gdb sudo locales curl bash-completion \
    && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-20 100 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-20 100 \
    && update-alternatives --install /usr/bin/clangd clangd /usr/bin/clangd-20 100 \
    && echo 'ubuntu ALL=(root) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
COPY scripts/bootstrap-sun.sh /usr/local/bin/install-sun-dev
RUN bash /usr/local/bin/install-sun-dev --update
RUN python3 -m venv /opt/vcs2l && /opt/vcs2l/bin/pip install --no-cache-dir vcs2l==1.1.7
ENV PATH="/opt/vcs2l/bin:${PATH}"
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CCACHE_MAXSIZE=10G
USER ubuntu
# Create mount destinations as the remote user so Docker does not create root-owned parents.
RUN mkdir -p /home/ubuntu/.vscode-server/data/User /home/ubuntu/.cache/ccache /home/ubuntu/.config/dconf
WORKDIR /workspaces/sun_video_editor
