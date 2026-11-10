# syntax=docker/dockerfile:1.6
FROM ubuntu:26.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_VERSION=26.13.0
ARG PYTHON_VERSION=3.14

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Europe/Berlin

# ---- Base system + build essentials ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git git-lfs openssh-server sudo locales tzdata \
        build-essential pkg-config \
        zsh tmux vim nano htop procps jq ripgrep fd-find bat unzip zip \
        iputils-ping dnsutils net-tools \
        python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev \
        python3-pip python3-setuptools pipx \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/local/bin/python3 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js via nvm (shared install so root and dev user both get it) ----
ARG NVM_VERSION=v0.40.8
ENV NVM_DIR=/usr/local/nvm
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install "${NODE_VERSION}" \
    && nvm alias default "${NODE_VERSION}" \
    && nvm use default \
    && npm install -g pnpm yarn \
    && chmod -R a+rwX "$NVM_DIR" \
    # Symlinks so node/npm/npx/pnpm/yarn are on PATH in any SSH session
    && ln -sf "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/node" /usr/local/bin/node \
    && ln -sf "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/npm"  /usr/local/bin/npm \
    && ln -sf "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/npx"  /usr/local/bin/npx \
    && ln -sf "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/pnpm" /usr/local/bin/pnpm \
    && ln -sf "$NVM_DIR/versions/node/v${NODE_VERSION}/bin/yarn" /usr/local/bin/yarn \
    # /etc/profile.d/ is bash-only; use zshenv for zsh login sessions
    && printf '%s\n' \
        'export NVM_DIR="/usr/local/nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        > /etc/profile.d/nvm.sh \
    && mkdir -p /etc/zsh \
    && printf '%s\n' \
        'export NVM_DIR="/usr/local/nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        >> /etc/zsh/zshenv \
    && node --version \
    && npm --version
ENV PATH=$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH

# ---- uv (fast Python package manager) ----
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# ---- Docker CLI only (no daemon). Talks to the DinD sidecar over TCP+TLS. ----
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI (handy for cloning private repos) ----
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---- KiCad 9 (headless use: kicad-cli + pcbnew Python API) ----
# From Ubuntu universe (9.0.x on 26.04). The GUI libs come along but are only
# needed for xvfb-run renders; nothing here requires a real display.
# 3D models (kicad-packages3d) are ~6 GB; only needed for STEP export with
# component bodies / enclosure fit checks. Enable with --build-arg INSTALL_KICAD_3D=true.
ARG INSTALL_KICAD_3D=false
RUN apt-get update && apt-get install -y --no-install-recommends \
        kicad kicad-symbols kicad-footprints kicad-templates \
        $( [ "$INSTALL_KICAD_3D" = "true" ] && echo kicad-packages3d ) \
        xvfb xauth librsvg2-bin imagemagick poppler-utils \
    && rm -rf /var/lib/apt/lists/* \
    && kicad-cli version \
    && /usr/bin/python3 -c "import pcbnew; print('pcbnew', pcbnew.Version())"

# ---- EDA Python env (sees system pcbnew via --system-site-packages) ----
# /opt/eda: kikit (fab outputs, JLC/PCBWay presets, panelization).
# build123d (enclosure CAD) is installed best-effort: its OCP wheels can lag
# new Python releases, and a missing CAD lib shouldn't break the devbox.
ARG INSTALL_CAD=true
RUN /usr/bin/python3 -m venv --system-site-packages /opt/eda \
    && /opt/eda/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/eda/bin/pip install --no-cache-dir kikit \
    && if [ "$INSTALL_CAD" = "true" ]; then \
         /opt/eda/bin/pip install --no-cache-dir build123d \
         || echo "WARN: build123d install failed (no wheels for this Python?) — skipping CAD"; \
       fi \
    && ln -sf /opt/eda/bin/python /usr/local/bin/eda-python \
    && ln -sf /opt/eda/bin/kikit  /usr/local/bin/kikit \
    && chmod -R a+rX /opt/eda

COPY bin/pcb-check /usr/local/bin/pcb-check
COPY templates/ /opt/kicad-templates/
RUN chmod +x /usr/local/bin/pcb-check

# ---- SSH server ----
RUN mkdir -p /var/run/sshd /etc/ssh/sshd_config.d
COPY sshd_dev.conf /etc/ssh/sshd_config.d/10-dev.conf

# ---- User setup ----
# Ubuntu 26.04 ships with a default "ubuntu" user/group at UID/GID 1000.
# Remove whatever currently owns our target UID/GID so we can claim them.
RUN set -eux; \
    if existing_user="$(getent passwd ${USER_UID} | cut -d: -f1)" && [ -n "$existing_user" ]; then \
        userdel --remove "$existing_user" || true; \
    fi; \
    if existing_group="$(getent group ${USER_GID} | cut -d: -f1)" && [ -n "$existing_group" ]; then \
        groupdel "$existing_group" || true; \
    fi; \
    groupadd --gid ${USER_GID} ${USERNAME}; \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/zsh ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}; \
    mkdir -p /home/${USERNAME}/.ssh /home/${USERNAME}/workspace; \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# The docker CLI talks to the dind daemon over TCP+TLS (DOCKER_HOST in the
# environment). No local docker socket, no group membership needed.

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22

# Exec form, no shell. Coolify's compose parser and CMD healthcheck
# whitelist both accept this. sshd is PID 1 after the entrypoint execs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
  CMD ["pgrep", "-x", "sshd"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
