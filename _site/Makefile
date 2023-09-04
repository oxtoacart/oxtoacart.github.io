.PHONY: build deploy

build:
	bundle exec jekyll build

deploy:
	git fetch && git push origin `git subtree split --prefix _site main`:gh-pages --force-with-lease