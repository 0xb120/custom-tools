# System-wide zsh aliases for engagement devcontainers.
# Installed to /etc/zsh/zshrc.d/aliases.zsh during image build
# (see org/templates/devcontainer/Dockerfile). Loaded automatically by the
# source loop appended to /etc/zsh/zshrc.
#
# Add aliases below; commit changes here to ship them to every new engagement.

# alias ll='ls -lah'
# alias gs='git status'
# alias hx='httpx -silent'
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'
alias bat='batcat'
alias ffuf='ffuf -c'
alias less='less -R'
alias semgrep-auto='semgrep --dataflow-traces --force-color --matching-explanations --json-output=scans/$(date +"%Y%m%d%H%M%S").json --text-output=scans/$(date +"%Y%m%d%H%M%S").txt --sarif-output=scans/$(date +"%Y%m%d%H%M%S").sarif --no-git-ignore'
alias semgrep-sarif='semgrep --dataflow-traces --force-color --text-output=scans/$(date +"%Y%m%d%H%M%S").txt --sarif-output=scans/$(date +"%Y%m%d%H%M%S").sarif --no-git-ignore'
alias claude-yolo="claude --dangerously-skip-permissions"
alias sshp="ssh -o PreferredAuthentications=password"
