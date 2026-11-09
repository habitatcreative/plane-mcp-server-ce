# Hardened build (habitatcreative fork): pinned base and uv images, dependencies
# installed from uv.lock (--frozen) so rebuilds of the same commit are identical,
# and the server runs as an unprivileged user.
FROM python:3.11.18-slim-bookworm

# curl stays available for container health checks.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /usr/local/bin/uv

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

# Dependencies first (cached layer), exactly as locked.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project

# Then the application itself.
COPY plane_mcp/ ./plane_mcp/
RUN uv sync --frozen --no-dev

RUN useradd --system --uid 10001 --no-create-home mcp
USER mcp

ENV PATH="/app/.venv/bin:$PATH" \
    FASTMCP_PORT=8211

# Streamable HTTP transport: /http/api-key/mcp
EXPOSE 8211

ENTRYPOINT ["python", "-m", "plane_mcp"]
CMD ["http"]
