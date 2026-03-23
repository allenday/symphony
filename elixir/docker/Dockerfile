FROM elixir:1.19-otp-28

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    openssh-client \
    nodejs \
    npm \
    python3-pip \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

RUN npm install --global @openai/codex

WORKDIR /opt/symphony/elixir

COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config
COPY elixir/lib ./lib
COPY elixir/priv ./priv
COPY elixir/WORKFLOW.docker.gitea.md ./WORKFLOW.docker.gitea.md
COPY elixir/WORKFLOW.docker.gitea.builder.md ./WORKFLOW.docker.gitea.builder.md
COPY elixir/WORKFLOW.docker.gitea.reviewer.md ./WORKFLOW.docker.gitea.reviewer.md
COPY elixir/WORKFLOW.docker.gitea.triage.md ./WORKFLOW.docker.gitea.triage.md
COPY elixir/WORKFLOW.docker.gitea.controller.md ./WORKFLOW.docker.gitea.controller.md

RUN mix local.hex --force \
 && mix local.rebar --force \
 && mix deps.get \
 && mix build

COPY elixir/docker/entrypoint.sh /usr/local/bin/symphony-compose-entrypoint
RUN chmod 755 /usr/local/bin/symphony-compose-entrypoint

ENTRYPOINT ["/usr/local/bin/symphony-compose-entrypoint"]
