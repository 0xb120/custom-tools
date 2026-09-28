# custom-tools

Personal dotfiles and a couple of small utility scripts.

The reusable penetration-testing toolkit — engagement scaffolder, report
generators, and templates — now lives in
[`sicuranext/offsec-utils`](https://github.com/sicuranext/offsec-utils).

## Contents

| Path                    | What it is                                         |
| ----------------------- | -------------------------------------------------- |
| `conf/config.ghostty`   | Ghostty terminal config                            |
| `conf/tmux.conf`        | tmux config                                        |
| `conf/zsh-aliases.zsh`  | zsh aliases                                        |
| `comparer.py`           | Print lines unique to each of two files            |
| `webm2gif.sh`           | Convert a `.webm` to `.gif` (ffmpeg)               |

## Usage

```sh
# Diff two files by unique lines
python3 comparer.py a.txt b.txt

# webm -> gif
./webm2gif.sh input.webm [output.gif] [--fast] [--scale WIDTH] [--fps N]
```

## Secrets

`conf/devcontainer.env` holds live API keys and is **gitignored** — it is never
committed. Keep it local only.
