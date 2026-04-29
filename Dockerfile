# Optional self-contained build for naive-proxy.
# Builds Caddy with klzgrad/forwardproxy@naive plugin via xcaddy and
# wraps it so that the CMD reads the Caddyfile from /etc/naiveproxy/Caddyfile.

FROM caddy:builder AS builder

RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

FROM caddy:latest

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

EXPOSE 80 443 443/udp

VOLUME ["/etc/naiveproxy", "/data", "/config"]

CMD ["caddy", "run", "--config", "/etc/naiveproxy/Caddyfile", "--adapter", "caddyfile"]
