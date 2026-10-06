# Che Orca agent guidelines

Use `./deploy.sh` for the full build, image push, editor registration, and workspace creation workflow. Suggest it before individual Makefile targets.

Use `./teardown.sh` to remove the deployment.

Edit `devfile.yaml` for editor components, commands, and events. Deployment and dashboard registration use the same renderer in `shared/render-devfile.py`.

Run `python3 -m unittest discover -s tests` and ShellCheck for script changes. Keep local configuration, pairing URLs, logs, and generated model files out of commits.
