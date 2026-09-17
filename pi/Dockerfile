#ddev-generated
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG USERNAME=pi
ARG USER_UID=1000
ARG USER_GID=1000
ARG PI_VERSION=latest
ARG YQ_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive
ENV USERNAME=${USERNAME}
ENV USER_HOME=/home/${USERNAME}

USER root

# Install base dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ripgrep \
       fd-find \
       ca-certificates \
       curl \
       openssh-client \
       sudo \
       python3-pip \
       python3-venv \
       python-is-python3 \
       git \
       jq \
       make \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Install yq (mikefarah/yq)
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) YQ_ARCH="amd64" ;; \
         arm64) YQ_ARCH="arm64" ;; \
         armhf) YQ_ARCH="arm" ;; \
         i386) YQ_ARCH="386" ;; \
         *) YQ_ARCH="${ARCH}" ;; \
       esac \
    && case "${YQ_VERSION}" in \
         latest) YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}" ;; \
         v*) YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" ;; \
         *) YQ_URL="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${YQ_ARCH}" ;; \
       esac \
    && curl -fsSL "${YQ_URL}" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Install Node.js LTS via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create user with matching UID/GID from host
RUN existing_user=$(getent passwd ${USER_UID} | cut -d: -f1) \
    && existing_group=$(getent group ${USER_GID} | cut -d: -f1) \
    && if [ -n "$existing_user" ] && [ "$existing_user" != "${USERNAME}" ]; then \
         userdel -r $existing_user 2>/dev/null || true; \
       fi \
    && if [ -n "$existing_group" ] && [ "$existing_group" != "${USERNAME}" ]; then \
         groupdel $existing_group 2>/dev/null || true; \
       fi \
    && groupadd --gid ${USER_GID} ${USERNAME} 2>/dev/null || true \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} 2>/dev/null || true \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && passwd -d ${USERNAME}

# Set up SSH client directory and config
RUN mkdir -p ${USER_HOME}/.ssh \
    && chown ${USER_UID}:${USER_GID} ${USER_HOME}/.ssh \
    && chmod 700 ${USER_HOME}/.ssh

COPY ssh-config ${USER_HOME}/.ssh/config
RUN chmod 600 ${USER_HOME}/.ssh/config \
    && chown ${USER_UID}:${USER_GID} ${USER_HOME}/.ssh/config

# Set up npm global and pi agent directories
RUN mkdir -p ${USER_HOME}/.npm-global \
    && mkdir -p ${USER_HOME}/.pi/agent/bin \
    && chown -R ${USER_UID}:${USER_GID} ${USER_HOME}/.npm-global \
    && chown -R ${USER_UID}:${USER_GID} ${USER_HOME}/.pi

# Copy and register entrypoint (as root, before USER switch)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Copy and configure web container tool forwarding proxy
COPY ddev-web-proxy /usr/local/bin/ddev-web-proxy
RUN chmod +x /usr/local/bin/ddev-web-proxy \
    && for tool in php composer drush phpunit phpstan phpcs phpcbf yarn npm; do \
         ln -sf /usr/local/bin/ddev-web-proxy /usr/local/bin/${tool}; \
       done

# ---------------------------------------------------------------------------
# build.d/ extensibility seam
#
# Scripts placed in .ddev/pi/build.d/ are copied here and executed as root
# in lexicographic (sorted) order before the image switches to the non-root
# "pi" user. This allows addons and users to install packages or perform
# other root-level setup without modifying this Dockerfile directly.
#
# Numeric naming bands:
#   00-09  Reserved for DDEV PI core
#   10-49  Runtimes and infrastructure packages
#   50-89  Tools and utilities
#   90-99  Project or user overrides
#
# To run something as the "pi" user from within a build script, use:
#   sudo -u ${USERNAME} <command>
# ---------------------------------------------------------------------------
COPY build.d/ /tmp/build.d/
RUN export USERNAME="${USERNAME}" \
           USER_UID="${USER_UID}" \
           USER_GID="${USER_GID}" \
           USER_HOME="${USER_HOME}" \
    && find /tmp/build.d -maxdepth 1 -name '*.sh' | sort | while read -r script; do \
        echo "[build.d] Running $script"; \
        chmod +x "$script"; \
        "$script"; \
    done \
    && rm -rf /tmp/build.d

USER ${USERNAME}
WORKDIR ${USER_HOME}

ENV HOME=${USER_HOME}
ENV NPM_CONFIG_PREFIX=${USER_HOME}/.npm-global
ENV PATH=${USER_HOME}/.pi/agent/bin:${USER_HOME}/.npm-global/bin:${USER_HOME}/.local/bin:${USER_HOME}/bin:$PATH

# Use /usr/bin/npm explicitly to bypass the /usr/local/bin/npm web proxy shim during image build.
RUN npm_config_update_notifier=false /usr/bin/npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}

# ---------------------------------------------------------------------------
# bashrc.d/ extensibility seam
#
# Scripts placed in .ddev/pi/bashrc.d/ are mounted into the container at
# /home/pi/.bashrc.d (see docker-compose.pi.yaml) and sourced by ~/.bashrc
# in sorted order when a user opens an interactive shell.
#
# This seam is interactive-shell-only. It does NOT affect PI's autonomous
# tool execution, which routes through agent extensions.
#
# Numeric naming bands:
#   00-09  Reserved for DDEV PI core
#   10-49  Environment and PATH setup
#   50-89  Tools and utilities
#   90-99  Project or user overrides
# ---------------------------------------------------------------------------
RUN echo 'export PATH="${HOME}/.npm-global/bin:${HOME}/go/bin:$PATH"' >> ~/.bashrc \
    && echo 'alias ll="ls -la"' >> ~/.bashrc \
    && echo '' >> ~/.bashrc \
    && echo '# Source all scripts from the mounted bashrc.d/ directory in sorted order.' >> ~/.bashrc \
    && echo '# An empty or missing directory is handled gracefully.' >> ~/.bashrc \
    && echo 'if [ -d "${HOME}/.bashrc.d" ]; then' >> ~/.bashrc \
    && echo '  for __bashrc_d_file in $(ls -1 "${HOME}/.bashrc.d"/*.sh 2>/dev/null | sort); do' >> ~/.bashrc \
    && echo '    # shellcheck source=/dev/null' >> ~/.bashrc \
    && echo '    [ -f "$__bashrc_d_file" ] && . "$__bashrc_d_file"' >> ~/.bashrc \
    && echo '  done' >> ~/.bashrc \
    && echo '  unset __bashrc_d_file' >> ~/.bashrc \
    && echo 'fi' >> ~/.bashrc \
    && echo '' >> ~/.bashrc

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

WORKDIR /var/www/html
