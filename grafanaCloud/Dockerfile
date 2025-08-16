FROM grafana/alloy:latest

RUN apt update && apt install -y curl net-tools

# Copy your Alloy config into the image
COPY config.alloy /etc/alloy/config.alloy

# Expose the ports you plan to use
EXPOSE 12345 4317 4318

# Run Alloy with your config; keep the HTTP server on 12345 and a local data dir
# ENTRYPOINT ["alloy"]
CMD ["run", "--server.http.listen-addr=0.0.0.0:12345", "--storage.path=/var/lib/alloy/data", "/etc/alloy/config.alloy"]
