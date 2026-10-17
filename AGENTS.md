# Che Orca agent guidelines

Use `./deploy.sh` for the full build, image push, editor registration, and workspace creation workflow. Suggest it before individual Makefile targets.

Use `./teardown.sh` to remove the deployment.

Edit `devfile.yaml` for editor components, commands, and events. Deployment and dashboard registration use the same renderer in `shared/render-devfile.py`.

Run ShellCheck for script changes. Keep local configuration, pairing URLs, and logs out of commits.

Write pull request descriptions with `.github/pull_request_template.md`: a plain-English summary first, then short technical bullets, then what was and wasn't tested. Keep them concise.
