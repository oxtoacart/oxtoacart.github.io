.PHONY: build deploy

build:
	bundle exec jekyll build

deploy: build
	cd _site && \
	git init && \
	git add . && \
	git commit -a -m"Deploying" && \
	git push --force git@github.com:oxtoacart/oxtoacart.github.io.git main:gh-pages && \
	rm -Rf .git
