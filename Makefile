IMAGE_NAME=test-install-desktop
FEATURES=default
TOOL=install_desktop.sh
GITREPO := $(shell grep url .git/config | sed 's/.*://;s/.git//')

.DEFAULT_GOAL := help

help:
	@echo $$(fgrep -h "## " $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/^\([a-z][a-z_\-]*\): ##/\\nmake \\\e[1;34m\1\\\e[0m\t:/g')

readme: ## update the README
	@echo  "# Ubuntu desktop\n\nRun the following command to install development tools:\n\`\`\`sh\ncurl -s https://gitlab.com/$(GITREPO)/raw/master/$(TOOL) | bash -s FEATURE ...\n\`\`\`\n">README.md
	@./$(TOOL) | tail -n +2 >>README.md


test: ## test script within a container
	mkdir -p .ssh && cp $$HOME/.ssh/id_rsa.pub .ssh
	docker build -t $(IMAGE_NAME):latest .
	docker run -it --rm $(IMAGE_NAME) /bin/bash -c "curl -s https://gitlab.com/$(GITREPO)/raw/master/install_desktop.sh | bash -s $(FEATURES)"



