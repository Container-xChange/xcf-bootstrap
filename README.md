# xcf-bootstrap

One-shot setup for a Container xChange development workspace — installs the tooling, clones the
repos you pick into `~/xcf`, and runs the engineering installer.

## Requirements

- macOS (Homebrew) or Linux (apt / pacman / dnf).
- Access to the Container-xChange org on GitHub (the script handles `gh` login).

## Run it

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Container-xChange/xcf-bootstrap/main/xcf-bootstrap.sh)
```

That's it — the script is interactive and walks you through the rest.

> Use the `bash <(curl …)` form above, **not** `curl … | bash`. Piping detaches the terminal, which
> breaks the interactive prompts and the repo picker.