# Setup GitHub Runner for nostrdb-zig

To complete the CI setup, you need to:

1. **Get a GitHub Runner Token:**
   - Go to https://github.com/justinmoon/nostrdb-zig/settings/actions/runners
   - Click "New self-hosted runner"
   - Copy the token from the configuration command (the long string after --token)

2. **On your Hetzner server, create the token file:**
   ```bash
   # SSH into your Hetzner server
   ssh root@your-hetzner-server

   # Create the token file
   echo "YOUR_GITHUB_RUNNER_TOKEN" > /var/lib/nostrdb-zig-runner-token
   chmod 600 /var/lib/nostrdb-zig-runner-token
   chown root:root /var/lib/nostrdb-zig-runner-token
   ```

3. **Deploy the updated configuration:**
   ```bash
   # From your local machine, in the configs repository
   cd ~/configs
   
   # Commit the runner changes
   git add hetzner/github-runner-factory.nix
   git commit -m "Add nostrdb-zig GitHub runner"
   git push
   
   # The GitOps pipeline should automatically deploy this, or you can manually trigger:
   # nixos-rebuild switch --flake .#hetzner
   ```

4. **Verify the runner is connected:**
   - Go back to https://github.com/justinmoon/nostrdb-zig/settings/actions/runners
   - You should see "nostrdb-zig-runner" listed as "Idle"

5. **Test the CI:**
   ```bash
   # In the nostrdb-zig repository
   git add .
   git commit -m "Add Nix flake and CI workflow"
   git push origin zig-flake-ci
   ```

The CI should now run on your self-hosted runner!