package WEC::Lirc::Constants;
use 5.008;
use strict;
use warnings;

use Exporter::Tidy
    other	=> [qw(PORT SOCKET LIRCRC_USER_FILE LIRCRC_ROOT_FILE LIRCD_FILE)];

use constant {
    # Default port
    PORT	=> 8765,
    # Default socket (on my system)
    SOCKET	=> "unix:///dev/lircd",
    LIRCRC_USER_FILE	=> "~/.lircrc",
    LIRCRC_ROOT_FILE	=> "/etc/lircrc",
    LIRCD_FILE		=> "/etc/lircd.conf",
};

1;
