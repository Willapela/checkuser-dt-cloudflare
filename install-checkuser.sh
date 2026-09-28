#!/bin/bash

# Cores
GREEN='\033[1;32m'
ROSA='\033[1;38;5;213m'   # rosa (destaques)
RED='\033[1;31m'
ROXO='\033[1;38;5;135m'   # roxo (moldura)
NC='\033[0m'

CHECK_BIN="/usr/local/bin/check"

clear
echo -e "${ROXO}"
echo "╔══════════════════════════════════════╗"
echo "║   CHECKUSER DTUNNEL + CLOUDFLARE     ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

# Verificar root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Execute como root!${NC}"
    exit 1
fi

# 1. Instalar CheckUser-Go
echo -e "${ROSA}[1/5] Instalando CheckUser-Go...${NC}"
TMP_CU_INSTALLER=$(mktemp)
curl -sL https://raw.githubusercontent.com/DTunnel0/CheckUser-Go/refs/heads/master/install.sh -o "$TMP_CU_INSTALLER"
# Remove a chamada final "main" do instalador oficial, pra não abrir o menu
# interativo dele (isso é o que causava a tela piscando sem parar)
sed -i '/^main$/d' "$TMP_CU_INSTALLER"
source "$TMP_CU_INSTALLER"
install_checkuser
rm -f "$TMP_CU_INSTALLER"

# 2. Instalar cloudflared
echo -e "${ROSA}[2/5] Instalando Cloudflare Tunnel...${NC}"
if ! command -v cloudflared &> /dev/null; then
    curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
fi

# 3. Criar serviço systemd para o túnel
echo -e "${ROSA}[3/5] Configurando serviço do túnel...${NC}"

cat > /etc/systemd/system/checkuser-tunnel.service << 'EOF'
[Unit]
Description=CheckUser Cloudflare Tunnel
After=network.target checkuser.service
Requires=checkuser.service

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --url http://localhost:2052
Restart=always
RestartSec=5
StandardOutput=append:/var/log/checkuser-tunnel.log
StandardError=append:/var/log/checkuser-tunnel.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable checkuser-tunnel
systemctl restart checkuser-tunnel

# 4. Esperar o link ser gerado
echo -e "${ROSA}[4/5] Gerando link do túnel...${NC}"
sleep 8

LINK=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/checkuser-tunnel.log | tail -1)

# 5. Instalar comando "check" (menu de gerenciamento)
echo -e "${ROSA}[5/5] Instalando comando 'check'...${NC}"

cat > "$CHECK_BIN" << 'MENUEOF'
#!/bin/bash

GREEN='\033[1;32m'
ROSA='\033[1;38;5;213m'   # rosa (destaques)
RED='\033[1;31m'
ROXO='\033[1;38;5;135m'   # roxo (moldura)
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

LOG_FILE="/var/log/checkuser-tunnel.log"
W=38   # largura interna da moldura

# ---------- helpers de desenho ----------
borda_topo()  { printf "${ROXO}╔"; printf '═%.0s' $(seq 1 $W); printf "╗${NC}\n"; }
borda_meio()  { printf "${ROXO}╠"; printf '═%.0s' $(seq 1 $W); printf "╣${NC}\n"; }
borda_base()  { printf "${ROXO}╚"; printf '═%.0s' $(seq 1 $W); printf "╝${NC}\n"; }

# linha "plain" (só ASCII, usado pra calcular o espaço) + "colored" (o que aparece)
linha() {
    local plain="$1" colored="$2"
    local pad=$((W - 2 - ${#plain}))
    [ $pad -lt 0 ] && pad=0
    printf "${ROXO}║${NC} %b%*s ${ROXO}║${NC}\n" "$colored" "$pad" ""
}

centro() {
    local txt="$1" cor="$2"
    local total=$((W - ${#txt}))
    local esq=$((total / 2))
    local dir=$((total - esq))
    printf "${ROXO}║${NC}%*s%b%*s${ROXO}║${NC}\n" "$esq" "" "${cor}${txt}${NC}" "$dir" ""
}

pausa() {
    echo ""
    read -rp "$(echo -e "${GRAY}  Pressione ENTER para voltar ao menu...${NC}")"
}

pegar_link() {
    grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -1
}

pegar_porta() {
    local p
    p=$(grep -o -- '--port [0-9]*' /etc/systemd/system/checkuser.service 2>/dev/null | awk '{print $2}')
    echo "${p:-2052}"
}

ok()   { echo -e "  ${GREEN}✔ $1${NC}"; }
aviso(){ echo -e "  ${ROSA}➜ $1${NC}"; }
erro() { echo -e "  ${RED}✘ $1${NC}"; }

menu() {
    clear

    # status dos serviços
    if systemctl is-active --quiet checkuser; then
        S1P="o ATIVO";  S1C="${GREEN}● ATIVO${NC}"
    else
        S1P="o PARADO"; S1C="${RED}● PARADO${NC}"
    fi
    if systemctl is-active --quiet checkuser-tunnel; then
        S2P="o ATIVO";  S2C="${GREEN}● ATIVO${NC}"
    else
        S2P="o PARADO"; S2C="${RED}● PARADO${NC}"
    fi
    PORTA=$(pegar_porta)
    LINK=$(pegar_link)

    echo ""
    borda_topo
    centro "CHECKUSER  MANAGER" "${ROSA}"
    centro "DTunnel + Cloudflare Tunnel" "${GRAY}"
    borda_meio
    linha "CheckUser : $S1P"  "${WHITE}CheckUser :${NC} $S1C"
    linha "Tunnel    : $S2P"  "${WHITE}Tunnel    :${NC} $S2C"
    linha "Porta     : $PORTA" "${WHITE}Porta     :${NC} ${ROSA}${PORTA}${NC}"
    borda_base

    echo -e "  ${WHITE}Link do túnel:${NC}"
    if [ -n "$LINK" ]; then
        echo -e "  ${ROSA}${LINK}${NC}"
    else
        echo -e "  ${GRAY}(nenhum link ativo)${NC}"
    fi
    echo ""

    borda_topo
    linha "[1] Iniciar servicos"        "${ROSA}[1]${NC} Iniciar serviços"
    linha "[2] Parar servicos"          "${ROSA}[2]${NC} Parar serviços"
    linha "[3] Reiniciar servicos"      "${ROSA}[3]${NC} Reiniciar serviços"
    linha "[4] Status detalhado"        "${ROSA}[4]${NC} Status detalhado"
    linha "[5] Ver link do tunel"       "${ROSA}[5]${NC} Ver link do túnel"
    linha "[6] Logs do tunel (ao vivo)" "${ROSA}[6]${NC} Logs do túnel (ao vivo)"
    borda_meio
    linha "[7] Desinstalar tudo"        "${RED}[7]${NC} ${RED}Desinstalar tudo${NC}"
    linha "[0] Sair"                    "${GRAY}[0]${NC} ${GRAY}Sair${NC}"
    borda_base
    echo ""
    read -rp "$(echo -e "  ${ROSA}Escolha uma opção ▸ ${NC}")" opcao
    echo ""

    case "$opcao" in
        1)
            systemctl start checkuser
            systemctl start checkuser-tunnel
            ok "Serviços iniciados."
            pausa
            ;;
        2)
            systemctl stop checkuser-tunnel
            systemctl stop checkuser
            aviso "Serviços parados."
            pausa
            ;;
        3)
            systemctl restart checkuser
            systemctl restart checkuser-tunnel
            ok "Serviços reiniciados."
            aviso "Gerando novo link, aguarde..."
            sleep 6
            L=$(pegar_link)
            echo -e "  ${WHITE}Novo link:${NC} ${ROSA}${L:-ainda gerando...}${NC}"
            pausa
            ;;
        4)
            systemctl status checkuser --no-pager
            echo ""
            systemctl status checkuser-tunnel --no-pager
            pausa
            ;;
        5)
            L=$(pegar_link)
            if [ -z "$L" ]; then
                erro "Nenhum link encontrado. O túnel está rodando?"
            else
                echo -e "  ${WHITE}Link atual:${NC}"
                echo -e "  ${ROSA}${L}${NC}"
            fi
            pausa
            ;;
        6)
            aviso "Pressione CTRL+C para sair dos logs."
            sleep 2
            tail -f "$LOG_FILE"
            ;;
        7)
            erro "Isso vai remover o CheckUser, o túnel e este menu por completo."
            read -rp "$(echo -e "  ${ROSA}Tem certeza? (s/N): ${NC}")" confirma
            if [[ "$confirma" =~ ^[sS]$ ]]; then
                aviso "Removendo túnel..."
                systemctl stop checkuser-tunnel 2>/dev/null
                systemctl disable checkuser-tunnel 2>/dev/null
                rm -f /etc/systemd/system/checkuser-tunnel.service

                aviso "Removendo CheckUser..."
                systemctl stop checkuser 2>/dev/null
                systemctl disable checkuser 2>/dev/null
                rm -f /etc/systemd/system/checkuser.service
                rm -f /usr/local/bin/checkuser

                systemctl daemon-reload

                rm -f "$LOG_FILE"
                ok "CheckUser, túnel e menu removidos com sucesso."
                echo "  Saindo..."
                rm -f /usr/local/bin/check
                exit 0
            else
                aviso "Cancelado."
            fi
            pausa
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            erro "Opção inválida."
            sleep 1
            ;;
    esac
    menu
}

menu
MENUEOF

chmod +x "$CHECK_BIN"

echo ""
echo -e "${ROXO}╔══════════════════════════════════════╗${NC}"
echo -e "${ROXO}║${ROSA}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!  ${ROXO}║${NC}"
echo -e "${ROXO}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  Link do CheckUser (use no app DTunnel):"
echo -e "  ${ROSA}$LINK${NC}"
echo ""
echo -e "  Digite ${ROXO}check${NC} a qualquer momento para abrir o menu."
echo ""
