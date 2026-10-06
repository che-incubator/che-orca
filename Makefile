include config.env
export
.DEFAULT_GOAL := build

ORCA_CONFIGMAP ?= orca-editor-definition

.PHONY: check-namespace build push devfile register unregister deploy teardown

check-namespace:
	@test -n "$(NAMESPACE)" || { echo "Set NAMESPACE in config.env before registering or removing Orca."; exit 1; }

build:
	podman build --platform linux/amd64 -f Containerfile -t $(ORCA_IMAGE) .

push:
	podman push $(ORCA_IMAGE)

devfile:
	python3 shared/render-devfile.py devfile.yaml --output devfile-rendered.yaml

register: check-namespace devfile
	oc create configmap $(ORCA_CONFIGMAP) \
	  --from-file=devfile-rendered.yaml \
	  -n $(NAMESPACE)
	oc label configmap $(ORCA_CONFIGMAP) \
	  app.kubernetes.io/part-of=che.eclipse.org \
	  app.kubernetes.io/component=editor-definition \
	  -n $(NAMESPACE)
	@rm -f devfile-rendered.yaml

unregister: check-namespace
	oc delete configmap $(ORCA_CONFIGMAP) -n $(NAMESPACE)

deploy:
	./deploy.sh

teardown:
	./teardown.sh
