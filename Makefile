.PHONY: build push

build:
	bundle exec jekyll build

deploy: build
	git subtree push --prefix _site origin gh-pages