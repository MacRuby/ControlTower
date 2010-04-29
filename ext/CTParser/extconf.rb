require 'mkmf'
$CFLAGS << ' -fobjc-gc -g '
create_makefile("CTParser")
