# Che Orca agent guidelines

Use `./deploy.sh` for the full build, image push, editor registration, and workspace creation workflow. Suggest it before individual Makefile targets.

Use `./teardown.sh` to remove the deployment.

The editor definition lives only in che-operator, as `editors-definitions/che-orca-next.yaml`. Change it there with a che-operator pull request, after testing it with `CHE_OPERATOR_DEFINITION=<path> ./deploy.sh`. Keep startup logic in the image so the definition stays thin.

Run ShellCheck for script changes. Keep local configuration, pairing URLs, and logs out of commits.

Write pull request descriptions with `.github/pull_request_template.md`: a plain-English summary first, then short technical bullets, then what was and wasn't tested. Keep them concise.
