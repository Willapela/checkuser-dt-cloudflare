# # CheckUser DT + Cloudflare Tunnel

Instalador automático do **CheckUser-Go** (DTunnel) já integrado com um **túnel Cloudflare** — sem precisar abrir porta, configurar domínio ou lidar com SSL na mão. Tudo em um único script, com um comando de gerenciamento (`check`) instalado no final.

## ✨ O que o script faz

- Instala o **CheckUser-Go** oficial (DTunnel0)
- Instala o **cloudflared** e cria um túnel público (`*.trycloudflare.com`)
- Cria um serviço `systemd` (`checkuser-tunnel`) para manter o túnel sempre ativo, com reinício automático
- Gera o link do túnel automaticamente ao final da instalação
- Instala o comando `check`, um **menu interativo** para gerenciar tudo depois

## 📦 Requisitos

- VPS/servidor com **Debian/Ubuntu**
- Acesso **root**
- Conexão com a internet liberada para GitHub e Cloudflare

## 🚀 Instalação

```bash
bash <(curl -sL https://raw.githubusercontent.com/Willapela/checkuser-dt-cloudflare/main/install-checkuser.sh)
```

Ao final, o script exibe o link do túnel — é esse link que você usa no app **DTunnel**.

## 🛠️ Gerenciando depois da instalação

Depois de instalado, basta digitar em qualquer lugar do terminal:

```bash
check
```

Isso abre o menu:

```
=========================================
          CHECKUSER - MENU DE GERENCIAMENTO
=========================================
 CheckUser : ATIVO
 Tunnel    : ATIVO
-----------------------------------------
  1) Iniciar serviços
  2) Parar serviços
  3) Reiniciar serviços
  4) Ver status detalhado
  5) Ver link do túnel atual
  6) Ver logs do túnel (tempo real)
  7) Desinstalar tudo
  0) Sair
=========================================
```

| Opção | O que faz |
|---|---|
| **1** | Inicia o CheckUser e o túnel |
| **2** | Para os dois serviços |
| **3** | Reinicia os dois e mostra o novo link gerado |
| **4** | Mostra `systemctl status` detalhado de ambos |
| **5** | Exibe o link ativo do túnel |
| **6** | Acompanha o log do túnel em tempo real (`tail -f`) |
| **7** | Remove **tudo**: CheckUser, túnel, serviços, logs e o próprio comando `check` |

## 📁 Onde fica cada coisa

| Item | Caminho |
|---|---|
| Binário do CheckUser | `/usr/local/bin/checkuser` |
| Serviço do CheckUser | `/etc/systemd/system/checkuser.service` |
| Serviço do túnel | `/etc/systemd/system/checkuser-tunnel.service` |
| Log do túnel | `/var/log/checkuser-tunnel.log` |
| Comando de gerenciamento | `/usr/local/bin/check` |

## ❌ Desinstalar

Pelo menu:

```bash
check
# opção 7
```

Isso remove o CheckUser, o túnel, os serviços do systemd, os logs e o próprio comando `check` — sem deixar resíduo no sistema.

## ⚠️ Aviso

Este projeto automatiza a instalação do [CheckUser-Go](https://github.com/DTunnel0/CheckUser-Go). Use por sua conta e risco em ambientes que você administra.
