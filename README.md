# Now Playing — indicador de mídia para o Wingpanel

Indicador para o painel do **elementary OS 8.x** que mostra a música atual no
painel e controles completos num popover. Funciona com qualquer player
compatível com **MPRIS** (Spotify, VLC, Rhythmbox, navegadores, Harmonia…).

## O que esta versão (0.1) faz

- **Painel:** ícone + "Título — Artista". Textos longos ficam com um esmaecimento
  à direita e rolam uma vez quando a música muda ou quando o mouse passa por cima.
- **Clique do meio** no painel: tocar/pausar.
- **Popover:** capa do álbum (cantos arredondados; capas 16:9 do YouTube são
  recortadas no centro), título, artista, álbum, barra de progresso com busca,
  aleatório, anterior, tocar/pausar, próxima e repetir (desligado → tudo → faixa).
- **Vários players:** abas com o ícone de cada app. O painel mostra o player que
  está tocando (ou o último que tocou).
- Clicar no nome do app no topo do popover traz a janela do player para a frente.
- Tradução para português do Brasil incluída.

## Compilar e instalar (elementary OS 8.1)

```bash
sudo apt install valac meson libwingpanel-dev libgtk-3-dev libsoup-3.0-dev gettext

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
│   └── ArtLoader.vala        # carrega capas (file://, http(s)://, data:)
└── Widgets/
    ├── MarqueeLabel.vala     # texto rolante do painel
    ├── AlbumArt.vala         # capa com cantos arredondados
    └── PlayerView.vala       # página de um player no popover
```

`Services/` não depende de GTK, então dá para reaproveitar quando o Wingpanel
migrar para GTK4 (elementary OS 9).

## Próximos passos

- Letra sincronizada (lrclib.net)
- Vinil animado
- Configurações (largura do texto, ocultar quando pausado)

## Licença

GPL-3.0-or-later
