project(
    'wingpanel-indicator-nowplaying',
    'vala', 'c',
    version: '0.1.0',
    license: 'GPL-3.0-or-later',
    meson_version: '>= 0.58.0'
)

gettext_name = 'nowplaying-indicator'
i18n = import('i18n')

prefix = get_option('prefix')
libdir = join_paths(prefix, get_option('libdir'))
localedir = join_paths(prefix, get_option('localedir'))

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
    'src/Services/MprisManager.vala',
    'src/Services/Player.vala',
    'src/Widgets/AlbumArt.vala',
    'src/Widgets/MarqueeLabel.vala',
    'src/Widgets/PlayerView.vala',
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('gtk+-3.0'),
        dependency('libsoup-3.0'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_indicatorsdir,
)

subdir('po')
