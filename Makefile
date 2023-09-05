.PHONY: build deploy

build:
	bundle exec jekyll build

deploy: build
	cd _site && \
	git pull && \
	git commit -a -m"Deploying" && \
	git push
