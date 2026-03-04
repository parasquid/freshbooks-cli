FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .
RUN gem build fb.gemspec && gem install freshbooks-cli-*.gem
RUN gem install rspec rspec-given webmock

ENTRYPOINT ["fb"]
