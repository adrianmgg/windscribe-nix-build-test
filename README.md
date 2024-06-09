> [!NOTE]
> in its current state this is able to launch into the UI and log into an account,
> but i haven't managed to get the vpn to connect yet

> [!NOTE]
> i knew basically nothing abt nix/nixpkgs stuff when i started this so there's probably a decent amount of jank/bad practices in here

# running

there's no service related stuff set up for this yet, so you'll need to manually start the helper
```bash
# (in another shell/run it in the background/etc)
sudo nix run .#windscribe_helper
```

then actually run the main windscribe executable
```bash
nix run .#
```




