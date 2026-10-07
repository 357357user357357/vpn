#!/bin/bash
# nc-tls-deploy.sh — automated HTTPS for Nextcloud on the RU relay.
# 1. If no LE cert yet: try to issue one (retries safely through LE rate limits).
# 2. If cert exists: deploy SSL vhost, HTTP->HTTPS redirect, Nextcloud
#    trusted_domains/overwrite settings, then reload Apache. Idempotent.
set -u
DOMAIN="readystart.fvds.ru"
# Prevent cron/manual overlap
exec 9>/var/lock/nc-tls.lock
flock -n 9 || { echo "[nc-tls] another run in progress; exiting"; exit 0; }
LEGO_PATH="/root/.lego-nc"
CERT="$LEGO_PATH/certificates/$DOMAIN.crt"
KEY="$LEGO_PATH/certificates/$DOMAIN.key"
WEBROOT="/var/www/acme-challenge"
SSL_CONF="/etc/apache2/sites-available/nextcloud-ssl.conf"
LOG_TAG="[nc-tls $(date '+%F %T')]"

echo "$LOG_TAG start"

# --- 1. Issue cert if missing -------------------------------------------
if [ ! -f "$CERT" ]; then
  timeout 280 lego run -a -m contacts@flexchat.top \
    --domains "$DOMAIN" \
    --http --http.webroot "$WEBROOT" \
    --path "$LEGO_PATH" 2>&1 | tail -2
  if [ ! -f "$CERT" ]; then
    echo "$LOG_TAG cert not issued yet (rate limit or network); will retry"
    exit 0
  fi
  echo "$LOG_TAG certificate issued"
fi

# --- 2. Deploy SSL vhost once -------------------------------------------
if [ ! -f "$SSL_CONF" ]; then
  cat > "$SSL_CONF" <<EOF
<VirtualHost *:443>
  DocumentRoot /var/www/nextcloud/
  ServerName $DOMAIN

  SSLEngine on
  SSLCertificateFile $CERT
  SSLCertificateKeyFile $KEY
  SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1

  Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"

  <Directory /var/www/nextcloud/>
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
    <IfModule mod_dav.c>
      Dav off
    </IfModule>
  </Directory>
</VirtualHost>
EOF
  a2ensite nextcloud-ssl >/dev/null 2>&1
  a2dissite default-ssl >/dev/null 2>&1
  echo "$LOG_TAG SSL vhost deployed"
fi

# --- 3. HTTP->HTTPS redirect on the :80 vhost (once) ---------------------
VHOST="/etc/apache2/sites-available/nextcloud.conf"
if ! grep -q "HTTPS redirect" "$VHOST"; then
  cat > /tmp/nc-redirect.txt <<'EOF'

# --- HTTPS redirect (added by nc-tls-deploy.sh) ---
RewriteEngine On
RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
RewriteRule ^(.*)$ https://readystart.fvds.ru$1 [R=301,L]
EOF
  # Insert before the closing </VirtualHost> of the :80 vhost
  python3 - <<'PYEOF'
import re
p = "/etc/apache2/sites-available/nextcloud.conf"
s = open(p).read()
block = open("/tmp/nc-redirect.txt").read()
if "</VirtualHost>" in s:
    s = s.replace("</VirtualHost>", block + "\n</VirtualHost>", 1)
    open(p, "w").write(s)
PYEOF
  echo "$LOG_TAG HTTP->HTTPS redirect added"
fi

# --- 4. Nextcloud settings ----------------------------------------------
if [ -f /var/www/nextcloud/occ ]; then
  cd /var/www/nextcloud
  run_occ() { sudo -u www-data php occ $@ 2>/dev/null; }
  # trusted_domains: find a free index
  IDX=1
  while run_occ config:system:get trusted_domains "$IDX" >/dev/null 2>&1; do IDX=$((IDX+1)); done
  run_occ config:system:set trusted_domains "$IDX" --value="$DOMAIN" >/dev/null
  run_occ config:system:set overwritehost --value="$DOMAIN" >/dev/null
  run_occ config:system:set overwriteprotocol --value=https >/dev/null
  run_occ config:system:set overwrite.cli.url --value="https://$DOMAIN" >/dev/null
  echo "$LOG_TAG nextcloud config updated (trusted_domains index $IDX)"
fi

# --- 5. Reload & verify --------------------------------------------------
if apachectl configtest 2>&1 | grep -q "Syntax OK"; then
  systemctl reload apache2
  sleep 1
  CODE=$(timeout 15 curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/index.php/login" || echo 000)
  echo "$LOG_TAG https login page -> HTTP $CODE"
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
    echo "$LOG_TAG SUCCESS — Nextcloud is on HTTPS"
  fi
else
  echo "$LOG_TAG apache configtest FAILED — check config manually"
  exit 1
fi
