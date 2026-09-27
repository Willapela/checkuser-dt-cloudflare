#!/bin/bash

# Cores
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

CHECK_BIN="/usr/local/bin/check"

clear
echo -e "${GREEN}"
echo "========================================="
echo "   CHECKUSER DTUNNEL + CLOUDFLARE TUNNEL"
echo "========================================="
echo -e "${NC}"

# Verificar root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Execute como root!${NC}"
    exit 1
fi

# 1. Instalar CheckUser-Go
echo -e "${YELLOW}[1/5] Instalando CheckUser-Go...${NC}"
TMP_CU_INSTALLER=$(mktemp)
curl -sL https://raw.githubusercontent.com/DTunnel0/CheckUser-Go/refs/heads/master/install.sh -o "$TMP_CU_INSTALLER"
# Remove a chamada final "main" do instalador oficial, pra não abrir o menu
# interativo dele (isso é o que causava a tela piscando sem parar)
sed -i '/^main$/d' "$TMP_CU_INSTALLER"
source "$TMP_CU_INSTALLER"
install_checkuser < /dev/null
rm -f "$TMP_CU_INSTALLER"

# 2. Instalar cloudflared
echo -e "${YELLOW}[2/5] Instalando Cloudflare Tunnel...${NC}"
if ! command -v cloudflared &> /dev/null; then
    curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
fi

# 3. Criar serviço systemd para o túnel
echo -e "${YELLOW}[3/5] Configurando serviço do túnel...${NC}"

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
echo -e "${YELLOW}[4/5] Gerando link do túnel...${NC}"
sleep 8

LINK=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /var/log/checkuser-tunnel.log | tail -1)

# 5. Instalar comando "check" (menu de gerenciamento)
echo -e "${YELLOW}[5/5] Instalando comando 'check'...${NC}"

cat > "$CHECK_BIN" << 'MENUEOF'
#!/bin/bash

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

LOG_FILE="/var/log/checkuser-tunnel.log"

pausa() {
    echo ""
    read -rp "Pressione ENTER para voltar ao menu..."
}

status_servico() {
    local nome="$1"
    if systemctl is-active --quiet "$nome"; then
        echo -e "${GREEN}ATIVO${NC}"
    else
        echo -e "${RED}PARADO${NC}"
    fi
}

pegar_link() {
    grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -1
}

menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}          CHECKUSER - MENU DE GERENCIAMENTO${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e " CheckUser : $(status_servico checkuser)"
    echo -e " Tunnel    : $(status_servico checkuser-tunnel)"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo "  1) Iniciar serviços"
    echo "  2) Parar serviços"
    echo "  3) Reiniciar serviços"
    echo "  4) Ver status detalhado"
    echo "  5) Ver link do túnel atual"
    echo "  6) Ver logs do túnel (tempo real)"
    echo "  7) Desinstalar tudo"
    echo "  0) Sair"
    echo -e "${CYAN}=========================================${NC}"
    read -rp "Escolha uma opção: " opcao

    case "$opcao" in
        1)
            systemctl start checkuser
            systemctl start checkuser-tunnel
            echo -e "${GREEN}Serviços iniciados.${NC}"
            pausa
            ;;
        2)
            systemctl stop checkuser-tunnel
            systemctl stop checkuser
            echo -e "${YELLOW}Serviços parados.${NC}"
            pausa
            ;;
        3)
            systemctl restart checkuser
            systemctl restart checkuser-tunnel
            echo -e "${GREEN}Serviços reiniciados.${NC}"
            sleep 5
            LINK=$(pegar_link)
            echo -e "Novo link: ${YELLOW}${LINK:-ainda gerando...}${NC}"
            pausa
            ;;
        4)
            echo ""
            systemctl status checkuser --no-pager
            echo ""
            systemctl status checkuser-tunnel --no-pager
            pausa
            ;;
        5)
            LINK=$(pegar_link)
            if [ -z "$LINK" ]; then
                echo -e "${RED}Nenhum link encontrado. O túnel está rodando?${NC}"
            else
                echo -e "Link atual: ${YELLOW}${LINK}${NC}"
            fi
            pausa
            ;;
        6)
            echo -e "${YELLOW}Pressione CTRL+C para sair dos logs.${NC}"
            sleep 2
            tail -f "$LOG_FILE"
            ;;
        7)
            echo -e "${RED}Isso vai remover o CheckUser, o túnel e este menu por completo.${NC}"
            read -rp "Tem certeza? (s/N): " confirma
            if [[ "$confirma" =~ ^[sS]$ ]]; then
                echo -e "${YELLOW}Removendo túnel...${NC}"
                systemctl stop checkuser-tunnel 2>/dev/null
                systemctl disable checkuser-tunnel 2>/dev/null
                rm -f /etc/systemd/system/checkuser-tunnel.service

                echo -e "${YELLOW}Removendo CheckUser...${NC}"
                systemctl stop checkuser 2>/dev/null
                systemctl disable checkuser 2>/dev/null
                rm -f /etc/systemd/system/checkuser.service
                rm -f /usr/local/bin/checkuser

                systemctl daemon-reload

                rm -f "$LOG_FILE"
                echo -e "${GREEN}CheckUser, túnel e menu removidos com sucesso.${NC}"
                echo "Saindo..."
                rm -f /usr/local/bin/check
                exit 0
            else
                echo "Cancelado."
            fi
            pausa
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Opção inválida.${NC}"
            pausa
            ;;
    esac
    menu
}

menu
MENUEOF

chmod +x "$CHECK_BIN"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "Link do CheckUser:"
echo -e "${YELLOW}$LINK${NC}"
echo ""
echo -e "Use este link no app DTunnel:"
echo -e "${YELLOW}$LINK${NC}"
echo ""
echo -e "Agora digite ${CYAN}check${NC} a qualquer momento para abrir o menu de gerenciamento."
echo ""
echo -e "Comandos úteis (sem o menu):"
echo "  systemctl status checkuser-tunnel"
echo "  systemctl restart checkuser-tunnel"
echo "  tail -f /var/log/checkuser-tunnel.log"
echo ""
