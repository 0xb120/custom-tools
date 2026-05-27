# syntax=docker/dockerfile:1.4
# Per-engagement Claude Code sandbox.
# Built once per engagement on `devcontainer up`. INSTALL_GROUPS and
# BASE_IMAGE are injected at scaffold time by org/newPT.sh based on the
# engagement type (web, external, internal, cloud, mobile, full, lite,
# none) and the chosen base distro (debian | kali).
#
# Build-time SSH: the git clone uses ssh-agent forwarding via BuildKit's
# `--mount=type=ssh`. The operator must have an ssh-agent running on the host
# with a GitHub-authorised key loaded (`ssh-add ~/.ssh/id_*`) before
# `devcontainer up`. devcontainer.json forwards the agent via --ssh=default.

ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ARG INSTALL_GROUPS=base,utils
ARG CUSTOM_TOOLS_REF=main

# Bootstrap: only the packages required to clone custom-tools and run the
# installer. zsh = default interactive shell for the pentester user;
# openssh-client = ssh + ssh-keyscan for the build-time git@github clone.
# Everything else lands via install-offsec-tools.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo bash zsh ca-certificates curl git openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Non-root user with passwordless sudo. install-offsec-tools.sh refuses to
# run when SUDO_USER is unset (its pre-flight check), so we satisfy that by
# invoking the installer via `sudo` from this user — pipx + Go tools then
# land in /home/pentester/ instead of /root/. UID pinned to 1000 to match
# the ssh-agent socket owner declared in --mount=type=ssh,uid=1000 below
# (and to align with the host operator's typical UID for bind-mount perms).
RUN useradd -m -u 1000 -s /bin/zsh pentester \
 && echo "pentester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pentester \
 && chmod 0440 /etc/sudoers.d/pentester

USER pentester
WORKDIR /home/pentester

# Clone custom-tools at the requested ref via SSH (repo is private), then run
# the installer with the engagement's group subset. ssh-keyscan seeds
# known_hosts so the non-interactive clone doesn't trip on the host-key prompt.
RUN --mount=type=ssh,uid=1000 \
    mkdir -p ~/.ssh \
 && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null \
 && git clone --depth 1 --branch "${CUSTOM_TOOLS_REF}" \
        git@github.com:0xb120/custom-tools.git /home/pentester/custom-tools \
 && sudo bash /home/pentester/custom-tools/org/install-offsec-tools.sh \
        --groups="${INSTALL_GROUPS}" /opt \
 && sudo install -m 0644 /home/pentester/custom-tools/org/conf/tmux.conf /etc/tmux.conf \
 && sudo install -d -m 0755 /etc/zsh/zshrc.d \
 && sudo install -m 0644 /home/pentester/custom-tools/org/conf/zsh-aliases.zsh /etc/zsh/zshrc.d/aliases.zsh \
 && echo 'for f in /etc/zsh/zshrc.d/*.zsh(N); do source "$f"; done' | sudo tee -a /etc/zsh/zshrc >/dev/null \
 && echo '# stub — system /etc/zsh/zshrc handles aliases and config' > ~/.zshrc

# Pin PATH at the image level so `docker exec` (and devcontainer exec) see the
# Go toolchain + the pentester user's pipx/.local/bin without needing a login
# shell. install-offsec-tools.sh already writes the same PATH to /etc/environment
# (for PAM-managed SSH sessions), but Docker's exec bypasses /etc/environment
# entirely — `docker exec` inherits the image-level ENV, so set it here too.
ENV PATH="/usr/local/go/bin:/home/pentester/go/bin:/home/pentester/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WORKDIR /workspace
