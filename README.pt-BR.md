# Now Playing — indicador de mídia para o Wingpanel

🇺🇸 [Read in English](README.md)

Indicador para o painel do **elementary OS 8.x** que mostra a música atual no
painel e controles completos num popover. Funciona com qualquer player
compatível com **MPRIS** (Spotify, VLC, Rhythmbox, navegadores, Harmonia…).

## Recursos (versão 0.4)

- **Painel:** ícone + "Título — Artista". Enquanto a música toca, títulos longos
  rolam continuamente (com uma pausa no começo de cada volta). Pausado, o texto
  para e rola uma vez ao passar o mouse.
- **Letra no painel** (opcional): em vez do nome da música, mostra o trecho que
  está sendo cantado. Linhas longas deslizam no tempo em que são cantadas. Sem
  letra sincronizada, volta a mostrar a música.
- **Clique do meio** no painel: tocar/pausar.
- **Popover:** capa do álbum (capas 16:9 do YouTube são recortadas no centro),
  título, artista, álbum, barra de progresso com busca, aleatório, anterior,
  tocar/pausar, próxima e repetir (desligado → tudo → faixa).
- **Vinil:** disco girando a 33⅓ rpm com a capa como selo. O braço desce quando a
  música toca, sobe quando pausa e avança para o centro conforme a música progride.
- **Letra sincronizada:** a linha atual fica em destaque e centralizada; clique numa
  linha para ir até aquele trecho. Rolar com o mouse pausa a rolagem automática
  por alguns segundos. Um selo mostra de onde veio a letra.
- **Modos:** botões no topo do popover, ou clique duas vezes na capa (vinil) e três
  vezes (letra). O modo escolhido é lembrado **para cada app**.
- **Vários players:** abas com o ícone de cada app.
- **Preferências** (no fim do popover): largura do texto no painel, letra no painel, mostrar artista,
  manter títulos rolando, mostrar quando nada estiver tocando.
- Respeita a opção do sistema de reduzir animações. Interface em inglês, com tradução para pt-BR.

## Fontes de letras

Consultadas nesta ordem; letra sincronizada sempre tem preferência sobre texto simples:

1. **O próprio player** — letra enviada nos metadados MPRIS (`xesam:asText`).
2. **Arquivos `.lrc` locais** — ao lado da música (`musica.mp3` → `musica.lrc`)
   ou em `~/.lyrics/Artista - Título.lrc` (ou `~/.lyrics/Título.lrc`).
   Útil para salvar à mão a letra de uma música que não foi encontrada.
3. **[LRCLIB](https://lrclib.net)** — banco aberto e gratuito (ligado por padrão).
4. **NetEase Cloud Music** — acervo enorme de música asiática. Acesso não oficial,
   pode parar de funcionar; desligado por padrão (ative nas preferências).

## Compilar e instalar (elementary OS 8.1)

```bash
sudo apt install valac meson libwingpanel-dev libgee-0.8-dev libgtk-3-dev \
    libsoup-3.0-dev libjson-glib-dev gettext

git clone https://github.com/maylton/wingpanel-indicator-nowplaying.git
cd wingpanel-indicator-nowplaying
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
killall io.elementary.wingpanel   # o painel reinicia sozinho
```

## Desinstalar

```bash
sudo ninja -C build uninstall
killall io.elementary.wingpanel
```

## Depurar

```bash
killall io.elementary.wingpanel; G_MESSAGES_DEBUG=NowPlaying io.elementary.wingpanel
```

## Estrutura

```
src/
├── Indicator.vala            # ponto de entrada do plugin, painel e popover
├── Services/
│   ├── MprisManager.vala     # descobre players no D-Bus
│   ├── Player.vala           # um player MPRIS (tudo assíncrono)
│   ├── ArtLoader.vala        # carrega capas (file://, http(s)://, data:)
│   ├── LyricsService.vala    # busca letras (player, .lrc, LRCLIB, NetEase)
│   └── Preferences.vala      # preferências (GSettings)
└── Widgets/
    ├── MarqueeLabel.vala     # texto rolante do painel
    ├── AlbumArt.vala         # capa com cantos arredondados
    ├── VinylView.vala        # vinil animado com braço
    ├── LyricsView.vala       # letra sincronizada
    ├── PlayerView.vala       # página de um player no popover
    └── SettingsView.vala     # página de preferências
data/
└── io.github.maylton.nowplaying.gschema.xml
```

`Services/` não depende de GTK, então dá para reaproveitar quando o Wingpanel
migrar para GTK4 (elementary OS 9).

## Idioma

A interface é em inglês e segue o idioma do sistema quando existe tradução.
Traduções disponíveis: português do Brasil (`pt_BR`). Para traduzir para outro
idioma, veja a seção *Translating* do [README em inglês](README.md#translating).

## Preferências pelo terminal

```bash
gsettings list-recursively io.github.maylton.nowplaying
gsettings set io.github.maylton.nowplaying panel-width 250
```

## Licença

GPL-3.0-or-later
