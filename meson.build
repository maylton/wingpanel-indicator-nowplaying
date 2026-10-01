project(
    'wingpanel-indicator-nowplaying',
    'vala', 'c',
    version: '0.4.0',
    license: 'GPL-3.0-or-later',
    meson_version: '>= 0.58.0'
)

gettext_name = 'nowplaying-indicator'
i18n = import('i18n')
gnome = import('gnome')

prefix = get_option('prefix')
libdir = join_paths(prefix, get_option('libdir'))
localedir = join_paths(prefix, get_option('localedir'))

# Vala-generated C triggers harmless warnings on newer GCC; keep the build output clean
cc = meson.get_compiler('c')
add_project_arguments(
    cc.get_supported_arguments([
        '-Wno-discarded-qualifiers',
        '-Wno-incompatible-pointer-types',
        '-Wno-unused-but-set-variable',
        '-Wno-unused-variable',
        '-Wno-unused-function',
    ]),
    language: 'c'
)

add_project_arguments(
    '-DGETTEXT_PACKAGE="@0@"'.format(gettext_name),
    '-DG_LOG_DOMAIN="NowPlaying"',
    language: 'c'
)

wingpanel_dep = dependency('wingpanel')
wingpanel_indicatorsdir = wingpanel_dep.get_variable('indicatorsdir', pkgconfig_define: ['libdir', libdir])

conf_data = configuration_data()
conf_data.set_quoted('GETTEXT_PACKAGE', gettext_name)
conf_data.set_quoted('LOCALEDIR', localedir)
config_file = configure_file(
    input: 'src/Config.vala.in',
    output: '@BASENAME@',
    configuration: conf_data
)

shared_module(
    'nowplaying',
    config_file,
    'src/Indicator.vala',
    'src/Services/ArtLoader.vala',
    'src/Services/LyricsService.vala',
    'src/Services/Preferences.vala',
    'src/Services/MprisManager.vala',
    'src/Services/Player.vala',
    'src/Widgets/AlbumArt.vala',
    'src/Widgets/LyricsView.vala',
    'src/Widgets/MarqueeLabel.vala',
    'src/Widgets/PlayerView.vala',
    'src/Widgets/SettingsView.vala',
    'src/Widgets/VinylView.vala',
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('gtk+-3.0'),
        meson.get_compiler('c').find_library('m', required: false),
        dependency('libsoup-3.0'),
        dependency('json-glib-1.0'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_indicatorsdir,
)

install_data(
    'data/io.github.maylton.nowplaying.gschema.xml',
    install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas')
)

subdir('po')

gnome.post_install(glib_compile_schemas: true)
