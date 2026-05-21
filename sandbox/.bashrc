# Sandbox user .bashrc
# Loaded by bash for interactive shells

# Ensure Nix default profile and user profile are in PATH
export PATH="/nix/var/nix/profiles/default/bin:/home/sandbox/.nix-profile/bin:$PATH"

# Nix flakes configuration (fallback if not already set via nix.conf)
export NIX_CONFIG="experimental-features = nix-command flakes"

# Use a readable prompt showing we're in the sandbox
PS1='[\u@\h \W]\$ '

# Enable color support for common commands if terminal supports it
if [ -t 1 ]; then
  alias ls='ls --color=auto'
  alias grep='grep --color=auto'
fi

# Useful aliases for the sandbox environment
alias nix-search='nix search nixpkgs'
alias nix-install='nix profile install'
alias nix-list='nix profile list'

# Ensure common directories exist
mkdir -p /home/sandbox/.config/nix /home/sandbox/.local/state/nix/profiles 2>/dev/null

