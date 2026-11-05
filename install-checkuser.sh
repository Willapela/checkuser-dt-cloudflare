#!/usr/bin/env bash
set -Eeuo pipefail

# CheckUser DTunnel + Void Pro+ (versão Python corrigida; não precisa de Go nem de binário).
#  - Contagem = sessões SSH/Dropbear abertas agora (sem cadastro de aparelho, sem "2/1" fantasma).
#  - Sempre responde limite, vencimento, dias e conexões, em qualquer forma de URL:
#      /check/{username}
#      /check?user={username}&uuid={uuid}&hwid={hwid}
# Serviço isolado para não conflitar com instalações antigas do CheckUser-Go.

APP_NAME="check-dt-voidpro"
SERVICE="${APP_NAME}.service"
TUNNEL_SERVICE="${APP_NAME}-tunnel.service"
INSTALL_DIR="/usr/local/lib/${APP_NAME}"
PYFILE="${INSTALL_DIR}/checkuser.py"
LIMITS_DB="${LIMITS_DB:-/root/usuarios.db}"
PORT="${PORT:-2052}"
LOG="/var/log/${APP_NAME}-tunnel.log"
MENU="/usr/local/bin/check"
ARCH="$(uname -m)"

GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✔${NC} $*"; }
warn(){ echo -e "${YELLOW}➜${NC} $*"; }
die(){ echo -e "${RED}✘${NC} $*" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || die "Execute como root."
[[ "$LIMITS_DB" != *[[:space:]]* ]] || die "LIMITS_DB não pode conter espaços."

# Evita alterar locks do apt: aguarda e falha claramente se outro apt estiver ativo.
wait_dpkg(){
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    n=$((n + 1))
    (( n <= 30 )) || die "apt/dpkg ocupado há muito tempo; tente novamente após o update terminar."
    sleep 2
  done
}

stop_old_services(){
  # Apenas unidades conhecidas do CheckUser-Go/versões anteriores; não mata serviços arbitrários.
  for unit in checkuser.service checkuser-go.service checkuser-min.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
      systemctl stop "$unit" 2>/dev/null || true
      systemctl disable "$unit" 2>/dev/null || true
      warn "Serviço antigo parado: $unit"
    fi
  done
  # Sobra de instalação anterior do CheckUser Python por drop-in: este instalador já define tudo na unidade.
  rm -f "/etc/systemd/system/${SERVICE}.d/zz-checkuser-py.conf"
  rmdir "/etc/systemd/system/${SERVICE}.d" 2>/dev/null || true
  systemctl daemon-reload
}

ensure_python(){
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 não encontrado; instalando..."
    wait_dpkg
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1 || die "Não consegui instalar o python3."
  fi
  PYBIN="$(command -v python3)"
  "$PYBIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' || die "Python 3.6 ou mais novo é necessário."
}

install_checkuser(){
  ensure_python
  mkdir -p "$INSTALL_DIR"
  local tmp="${PYFILE}.new"
  cat > "$tmp" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CheckUser (SSH) para DTunnel e Void Pro+.

Resolve dois problemas dos CheckUser baseados em CheckUser-Go:

  1. "2/1" com o usuario desconectado: o Go conta dispositivos gravados em
     /root/db.sqlite3. Aqui NAO existe cadastro de dispositivo: a contagem sao
     as sessoes SSH/Dropbear realmente abertas agora.
  2. App sem limite/vencimento: com ?uuid= preenchido o binario do check-final
     responde so {"error": "uuid not found"}. Aqui toda consulta devolve os
     mesmos campos, qualquer que seja a forma da URL.

Rotas aceitas (uuid, hwid e device sao aceitos e ignorados):
  /check/<usuario>
  /check/<usuario>/<device>
  /check?user=<usuario>&uuid=...&hwid=...      (tambem username=, login=)
  /health

Dependencias: apenas Python 3.6+ (biblioteca padrao). Rode como root.
"""
import argparse
import datetime as dt
import json
import os
import pwd
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, unquote, urlsplit

VERSION = "py-1.0.1"
USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
USER_KEYS = ("user", "username", "login", "u")

CFG = {
    "limits_db": "/root/usuarios.db",   # linhas "usuario limite" (SSHPlus)
    "default_limit": 1,                 # usado se o usuario nao estiver no arquivo
    "min_uid": 1000,                    # nao expoe contas de sistema
    "no_expiry": dt.date(2099, 12, 31),  # mostrado quando a conta nunca expira
}

_limits_lock = threading.Lock()
_limits_cache = {"mtime": None, "data": {}}


def read_limits():
    """Le o arquivo de limites; so reabre quando o arquivo muda."""
    path = CFG["limits_db"]
    try:
        mtime = os.stat(path).st_mtime_ns
    except OSError:
        return {}
    with _limits_lock:
        if _limits_cache["mtime"] == mtime:
            return _limits_cache["data"]
        data = {}
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 2 and not parts[0].startswith("#") and parts[1].isdigit():
                        data[parts[0]] = int(parts[1])  # em duplicata vale a ultima linha
        except OSError:
            return {}
        _limits_cache["mtime"] = mtime
        _limits_cache["data"] = data
        return data


def expiry_from_chage(user):
    env = {"LC_ALL": "C", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}
    try:
        out = subprocess.run(
            ["chage", "-l", user], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            universal_newlines=True, timeout=5, env=env,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"Account expires\s*:\s*(.+)", out)
    if not m:
        return None
    try:
        return dt.datetime.strptime(m.group(1).strip(), "%b %d, %Y").date()
    except ValueError:
        return None


def account_expiry(user):
    """Data em que a conta expira, ou None se nunca expira."""
    try:
        with open("/etc/shadow", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                fields = line.rstrip("\n").split(":")
                if fields and fields[0] == user:
                    raw = fields[7].strip() if len(fields) > 7 else ""
                    if raw.lstrip("-").isdigit() and int(raw) >= 0:
                        try:
                            return dt.date(1970, 1, 1) + dt.timedelta(days=int(raw))
                        except (OverflowError, ValueError):
                            return None
                    return None
        return None
    except OSError:
        return expiry_from_chage(user)


def count_sessions(user, uid):
    """Conexoes abertas agora: sessoes sshd do usuario + processos dropbear dele."""
    total = 0
    prefix = "sshd: " + user
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return 0
    for pid in pids:
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                cmd = fh.read(512).replace(b"\0", b" ").decode("utf-8", "replace").strip()
            if cmd.startswith("sshd:"):
                if cmd.startswith(prefix):
                    rest = cmd[len(prefix):]
                    # "sshd: user@pts/0" / "sshd: user@notty" = sessao.
                    # "sshd: user [priv]" e "[net]" sao processos auxiliares: nao contam.
                    if rest == "" or rest.startswith("@"):
                        total += 1
                continue
            with open("/proc/%s/comm" % pid, "r") as fh:
                comm = fh.read().strip()
            if comm == "dropbear" and os.stat("/proc/%s" % pid).st_uid == uid:
                total += 1
        except OSError:
            continue  # processo terminou durante a leitura
    return total


def build_payload(user):
    """Retorna (status_http, dict)."""
    if not USER_RE.match(user):
        return 400, {"error": "invalid user"}
    try:
        entry = pwd.getpwnam(user)
    except KeyError:
        return 404, {"error": "user not found"}
    if entry.pw_uid < CFG["min_uid"]:
        return 404, {"error": "user not found"}

    expiry = account_expiry(user) or CFG["no_expiry"]
    # Dias INTEIROS restantes (a conta expira a 00:00 da data), igual ao binario
    # original: vence 22/11 e hoje e 03/11 as 20h -> mostra 1 dia a menos que a
    # diferenca de datas. Conta vencida mostra 0.
    remaining = dt.datetime.combine(expiry, dt.time.min) - dt.datetime.now()
    days = max(0, remaining.days)
    limit = read_limits().get(user, CFG["default_limit"])
    return 200, {
        "id": entry.pw_uid,
        "username": user,
        "expiration_date": expiry.strftime("%d/%m/%Y"),
        "expiration_days": days,
        "limit_connections": limit,
        "count_connections": count_sessions(user, entry.pw_uid),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "CheckUser-Py/" + VERSION
    timeout = 10

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, indent=1).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parts = urlsplit(self.path)
        segs = [unquote(s) for s in parts.path.split("/") if s]
        query = parse_qs(parts.query)

        if not segs or segs[0] in ("health", "healthz"):
            self._send(200, {"status": "ok", "service": "checkuser", "version": VERSION})
            return
        if segs[0] != "check":
            self._send(404, {"error": "not found"})
            return

        user = segs[1] if len(segs) > 1 else None
        if not user:
            for key in USER_KEYS:
                if query.get(key) and query[key][0]:
                    user = query[key][0]
                    break
        if not user:
            self._send(400, {"error": "user is required"})
            return

        status, payload = build_payload(user.strip())
        self._send(status, payload)

    do_HEAD = do_GET


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def main():
    ap = argparse.ArgumentParser(description="CheckUser SSH para DTunnel e Void Pro+")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=2052)
    ap.add_argument("--limits-db", default=CFG["limits_db"])
    ap.add_argument("--default-limit", type=int, default=CFG["default_limit"])
    ap.add_argument("--min-uid", type=int, default=CFG["min_uid"])
    ap.add_argument("--check", metavar="USUARIO", help="imprime a resposta de um usuario e sai")
    ap.add_argument("--version", "-version", action="store_true")
    # Flags do servico antigo, aceitas e ignoradas para nao quebrar o ExecStart:
    ap.add_argument("--start", "-start", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--dragoncore-url", "-dragoncore-url", default=None, help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.version:
        print("checkuser " + VERSION)
        return 0

    CFG["limits_db"] = args.limits_db
    CFG["default_limit"] = args.default_limit
    CFG["min_uid"] = args.min_uid

    if args.check:
        status, payload = build_payload(args.check)
        print(json.dumps(payload, ensure_ascii=False, indent=1))
        return 0 if status == 200 else 1

    server = Server((args.host, args.port), Handler)
    sys.stderr.write("checkuser %s ouvindo em %s:%d (limites: %s)\n"
                     % (VERSION, args.host, args.port, CFG["limits_db"]))
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 0755 "$tmp"
  "$PYBIN" -I "$tmp" --version >/tmp/check-dt-voidpro-version 2>&1 || die "Não consegui executar o CheckUser em Python."
  grep -qi 'checkuser' /tmp/check-dt-voidpro-version || die "Versão inesperada: $(cat /tmp/check-dt-voidpro-version)"
  mv -f "$tmp" "$PYFILE"
  ok "CheckUser instalado: $PYFILE ($(cat /tmp/check-dt-voidpro-version))"
}

configure_service(){
  [[ -r "$LIMITS_DB" ]] || die "Arquivo de limites não encontrado: $LIMITS_DB"
  # Espera linhas 'usuario limite'. Não alteramos o banco do SSHPlus.
  local count
  count=$(awk 'NF >= 2 && $1 !~ /^#/ && $2 ~ /^[0-9]+$/ {n++} END {print n+0}' "$LIMITS_DB")
  (( count > 0 )) || warn "Nenhuma linha 'usuario limite' foi detectada em $LIMITS_DB; verifique o formato."

  stop_old_services
  systemctl stop "$TUNNEL_SERVICE" 2>/dev/null || true
  systemctl disable "$TUNNEL_SERVICE" 2>/dev/null || true
  systemctl stop "$SERVICE" 2>/dev/null || true

  # Libera somente a porta configurada; o usuário deve conferir se outro serviço a usa.
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  cat > "/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=CheckUser DTunnel + Void Pro+ (Python, isolated)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PYBIN} -I ${PYFILE} --host 0.0.0.0 --port ${PORT} --limits-db ${LIMITS_DB}
Restart=always
RestartSec=3
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" || { systemctl status "$SERVICE" --no-pager; die "CheckUser não iniciou."; }
  curl -fsS -m 5 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 || warn "CheckUser ativo, mas sem resposta em /health na porta ${PORT}."
  ok "CheckUser ativo em ${PORT}; contagem: sessões SSH/Dropbear; limites: ${LIMITS_DB}"
}

install_tunnel(){
  local cf=""
  if command -v cloudflared >/dev/null 2>&1; then cf=$(command -v cloudflared)
  else
    wait_dpkg
    local cf_arch='amd64'; [[ "$ARCH" == aarch64 || "$ARCH" == arm64 ]] && cf_arch='arm64'
    local deb="/tmp/cloudflared-${cf_arch}.deb"
    if curl -fL --retry 3 -o "$deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}.deb" && dpkg -i "$deb" >/dev/null 2>&1; then
      rm -f "$deb"; cf=$(command -v cloudflared || true)
    fi
    rm -f "$deb"
    if [[ -z "$cf" ]]; then
      warn "Pacote cloudflared indisponível; usando binário direto..."
      local cf_bin="/usr/local/bin/cloudflared"
      if curl -fL --retry 3 -o "$cf_bin" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"; then
        chmod 0755 "$cf_bin"
        cf="$cf_bin"
      fi
    fi
  fi
  if [[ -z "$cf" ]]; then
    warn "cloudflared não foi instalado; o CheckUser continua funcionando por IP:porta."
    return 0
  fi
  cat > "/etc/systemd/system/${TUNNEL_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for ${APP_NAME}
After=network-online.target ${SERVICE}
Requires=${SERVICE}

[Service]
Type=simple
ExecStart=${cf} tunnel --url http://127.0.0.1:${PORT}
Restart=always
RestartSec=5
StandardOutput=append:${LOG}
StandardError=append:${LOG}

[Install]
WantedBy=multi-user.target
EOF
  : > "$LOG"
  systemctl daemon-reload
  systemctl enable "$TUNNEL_SERVICE" >/dev/null
  systemctl restart "$TUNNEL_SERVICE"
  sleep 2
  if systemctl is-active --quiet "$TUNNEL_SERVICE"; then
    ok "Cloudflare Tunnel ativo."
  else
    warn "Cloudflare Tunnel não iniciou; o CheckUser continua ativo por IP:porta."
    systemctl status "$TUNNEL_SERVICE" --no-pager -l || true
    tail -n 30 "$LOG" 2>/dev/null || true
  fi
}

install_menu(){
  cat > "$MENU" <<'MENU_EOF'
#!/usr/bin/env bash
APP_NAME="check-dt-voidpro"
SERVICE="${APP_NAME}.service"
TUNNEL_SERVICE="${APP_NAME}-tunnel.service"
PORT="2052"
LOG="/var/log/${APP_NAME}-tunnel.log"
MENU="/usr/local/bin/check"
GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;35m'; WHITE=$'\033[1;37m'; GRAY=$'\033[0;90m'; NC=$'\033[0m'
link(){
  local l
  l=$(grep -Eo 'https://[^[:space:]]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tr -d '"' | tail -1 || true)
  if [[ -z "$l" ]]; then
    l=$(journalctl -u "$TUNNEL_SERVICE" --no-pager -n 100 -o cat 2>/dev/null | grep -Eo 'https://[^[:space:]]+\.trycloudflare\.com' | tr -d '"' | tail -1 || true)
  fi
  printf '%s' "$l"
}
line(){ printf '%s║%s %-18s %-35s %s║%s\n' "$CYAN" "$NC" "$1" "$2" "$CYAN" "$NC"; }
box(){ printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$CYAN" "$NC"; }
endbox(){ printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$CYAN" "$NC"; }
sep(){ printf '%s╠══════════════════════════════════════════════════════════════╣%s\n' "$CYAN" "$NC"; }
show(){
  local l cs ts db; l=$(link); cs=$(systemctl is-active "$SERVICE" 2>/dev/null || true); ts=$(systemctl is-active "$TUNNEL_SERVICE" 2>/dev/null || true); db=$(systemctl cat "$SERVICE" 2>/dev/null | sed -n 's/.*--limits-db \([^ ]*\).*/\1/p' | tail -1)
  clear; echo; box; printf '%s║%s %-58s %s║%s\n' "$CYAN" "$NC" "CHECKUSER CONTROL PANEL" "$CYAN" "$NC"; printf '%s║%s %-58s %s║%s\n' "$CYAN" "$GRAY" "DTunnel  •  Void Pro+  •  CheckUser Python" "$CYAN" "$NC"; sep; line "CheckUser" "${cs:-unknown}"; line "Cloudflare" "${ts:-unknown}"; line "Porta" "$PORT"; line "Fonte" "Sessoes SSH/Dropbear"; endbox
  echo; printf '%sLINK PÚBLICO / DTUNNEL%s\n' "$WHITE" "$NC"; printf '%s%s%s\n' "$GREEN" "${l:-Link ainda não gerado}" "$NC"; echo; printf '%sURL DO VOID PRO+%s\n' "$WHITE" "$NC"; printf '%s%s/check?user={username}&uuid={uuid}&hwid={hwid}%s\n' "$GREEN" "${l:-http://IP_DA_VPS:$PORT}" "$NC"; [[ -z "$l" ]] && printf '%sDiagnóstico: opção 5 ou journalctl -u %s%s\n' "$YELLOW" "$TUNNEL_SERVICE" "$NC"; echo;
}
while true; do show; box; echo "  [1] Iniciar serviços"; echo "  [2] Parar serviços"; echo "  [3] Reiniciar e gerar link"; echo "  [4] Status detalhado"; echo "  [5] Ver logs do Cloudflare"; echo "  [6] Atualizar tela/links"; echo "  [7] Remover CheckUser + Tunnel"; echo "  [0] Sair"; endbox; echo; read -r -p 'Opção: ' op; case "$op" in 1) systemctl start "$SERVICE"; systemctl start "$TUNNEL_SERVICE" 2>/dev/null || true;; 2) systemctl stop "$TUNNEL_SERVICE" "$SERVICE" 2>/dev/null;; 3) : > "$LOG"; systemctl restart "$SERVICE"; systemctl restart "$TUNNEL_SERVICE" 2>/dev/null || true; for _ in {1..10}; do [[ -n "$(link)" ]] && break; sleep 2; done;; 4) systemctl status "$SERVICE" "$TUNNEL_SERVICE" --no-pager -l;; 5) clear; echo '== arquivo de log =='; tail -n 100 "$LOG" 2>/dev/null || true; echo; echo '== journalctl =='; journalctl -u "$TUNNEL_SERVICE" --no-pager -n 100 -o cat 2>/dev/null || true;; 6) :;; 7) echo; read -r -p 'Remover somente este CheckUser e Tunnel? (s/N): ' confirm; if [[ "$confirm" =~ ^[sS]$ ]]; then systemctl disable --now "$TUNNEL_SERVICE" "$SERVICE" 2>/dev/null || true; rm -f "/etc/systemd/system/$TUNNEL_SERVICE" "/etc/systemd/system/$SERVICE" "$MENU" "$LOG"; rm -rf /usr/local/lib/$APP_NAME; systemctl daemon-reload; echo "Removido. /root/usuarios.db e SSHPlus foram preservados."; exit 0; fi;; 0) clear; exit 0;; esac; [[ "$op" != 6 ]] && read -r -p 'ENTER para continuar' _; done
MENU_EOF
  chmod 0755 "$MENU"
}

install_checkuser
configure_service
install_tunnel
install_menu

echo -e "\n${GREEN}CheckUser instalado com sucesso.${NC}"
echo "Serviço: $SERVICE"
echo "Porta: ${PORT}"
echo "Arquivo de limites: ${LIMITS_DB}"
sample="$(awk 'NF>=2 && $1 !~ /^#/ && $2 ~ /^[0-9]+$/ {print $1; exit}' "$LIMITS_DB" 2>/dev/null || true)"
if [[ -n "$sample" ]]; then
  echo; echo -e "${CYAN}Teste com o usuário ${sample}:${NC}"
  "$PYBIN" -I "$PYFILE" --limits-db "$LIMITS_DB" --check "$sample" || true
fi
echo
echo "DTunnel/Void: digite check para ver os links"
echo "O link do Cloudflare muda quando o serviço reinicia: atualize a URL no app com o link novo."

exit 0
