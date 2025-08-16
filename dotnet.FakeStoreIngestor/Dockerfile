# =========================
#  Build stage
# =========================
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Refresh CA certs (Debian/Ubuntu base)
USER root

# ## Updates package lists and installs curl and CA certificates.
# RUN apt update && apt install -y curl ca-certificates

# ## Copy certificates from the build context
# COPY zcert.crt /usr/local/share/ca-certificates/

# ## Update certificates to ensure they are recognized
# RUN update-ca-certificates --fresh

# Copy csproj first for better layer caching
COPY FakeStoreIngestor.csproj ./

# RUN dotnet --info && dotnet nuget list source
# RUN curl -I https://api.nuget.org/v3/index.json || true
# RUN ls -la && echo "----" && cat FakeStoreIngestor.csproj || true

RUN dotnet restore FakeStoreIngestor.csproj

# Copy the rest and publish
COPY . .
RUN dotnet publish FakeStoreIngestor.csproj -c Release -o /app/publish /p:UseAppHost=false

# =========================
#  Runtime stage
# =========================
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app

USER root

# ## Updates package lists and installs curl and CA certificates.
# RUN apt update && apt install -y curl ca-certificates

# ## Copy certificates from the build context
# COPY zcert.crt /usr/local/share/ca-certificates/

# ## Update certificates to ensure they are recognized
# RUN update-ca-certificates --fresh

ARG OTEL_VERSION=1.4.0
ADD https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v${OTEL_VERSION}/otel-dotnet-auto-install.sh otel-dotnet-auto-install.sh
RUN apt-get update && apt-get install -y curl unzip && \
OTEL_DOTNET_AUTO_HOME="/otel-dotnet-auto" sh otel-dotnet-auto-install.sh && \
chmod +x /otel-dotnet-auto/instrument.sh

ENV OTEL_DOTNET_AUTO_HOME="/otel-dotnet-auto"

# ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317
ENV OTEL_SERVICE_NAME=FakeStoreIngestor
# ENV OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production
# ENV OTEL_RESOURCE_ATTRIBUTES=service.namespace=sample,deployment.environment=production,service.instance.id=hostname1,service.version=v1.1
ENV OTEL_RESOURCE_ATTRIBUTES=sandbox

# Create non-root user
RUN adduser --disabled-password --gecos "" appuser && chown -R appuser /app

RUN apt-get update && apt-get install -y curl

USER appuser

# App listens on 5171 by default
ENV ASPNETCORE_URLS=http://0.0.0.0:5171
EXPOSE 5171

# (Optional) default config you can override at runtime
# MySQL connection (override in prod via -e or compose)
ENV ConnectionStrings__Default="Server=127.0.0.1;Port=3306;Database=fakestore;User=appuser;Password=apppass;TreatTinyAsBoolean=false;DefaultCommandTimeout=30"
# Upstream API (override in CI to point at mock)
# ENV Ingest__BaseUrl="https://fakestoreapi.com/"
ENV Ingest__BaseUrl="http://127.0.0.1:3000/"
ENV Ingest__ProductsEndpoint="products"

# Copy published output
COPY --from=build /app/publish ./

# # Healthcheck hits your /health endpoint
# HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
#   CMD wget -qO- http://localhost:8080/health || exit 1

# Run
# ENTRYPOINT ["dotnet", "FakeStoreIngestor.dll"]
ENTRYPOINT ["/otel-dotnet-auto/instrument.sh", "dotnet", "FakeStoreIngestor.dll"]
