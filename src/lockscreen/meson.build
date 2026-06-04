lockscreen_sources = [
  'lock_screen.vala',
  'lock_surface.c',
  'lock_surface.vapi',
  'pam_auth.c',
]

pam_dep = cc.find_library('pam', required: true)

executable('singularity-lockscreen', lockscreen_sources,
  sources: [sl_proto_c, sl_proto_h],
  dependencies: dependencies + [
    libsingularity_dep,
    gee_dep,
    pam_dep
  ],
  include_directories: [
    include_directories('.'),
    include_directories('..'),
  ],
  install: true
)

install_data(
  'dev.sinty.lockscreen.gschema.xml',
  install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas')
)

install_data(
  'singularity-lockscreen.pam',
  install_dir: '/etc/pam.d',
  rename: 'singularity-lockscreen'
)