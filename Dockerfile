FROM ghcr.io/namo-robotics/sun-dev:ubuntu26.04-llvm20

USER root

# Editor libraries, media tools, and headless test support.
RUN apt-get update && apt-get install -y --no-install-recommends \
    dbus-x11 \
    ffmpeg \
    fonts-dejavu-core \
    fonts-noto-core \
    gobject-introspection \
    gstreamer1.0-libav \
    gstreamer1.0-pipewire \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly \
    libgirepository1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer1.0-dev \
    libgtk-4-dev \
    librsvg2-dev \
    libx11-dev \
    libxext-dev \
    xauth \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/bootstrap-sun.sh /usr/local/bin/install-sun-dev
RUN bash /usr/local/bin/install-sun-dev --update
# Install transitive system requirements before builds run as an unprivileged user.
COPY sun-config.json /tmp/sun-dependencies/sun-config.json
RUN cd /tmp/sun-dependencies && apt-get update \
    && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf \
       GIT_CONFIG_VALUE_0=git@github.com: sun dep install --config sun-config.json --yes \
    && cd / && rm -rf /tmp/sun-dependencies /var/lib/apt/lists/*
USER ubuntu
WORKDIR /workspaces/sun_video_editor
